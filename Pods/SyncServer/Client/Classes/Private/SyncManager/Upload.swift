//
//  Upload.swift
//  SyncServer
//
//  Created by Christopher Prince on 2/28/17.
//
//

import Foundation
import SMCoreLib
import SyncServer_Shared

class Upload {
    var desiredEvents:EventDesired!
    weak var delegate:SyncServerDelegate?
    
    static let session = Upload()
    var deviceUUID:String!
    private var completion:((NextCompletion)->())?
    
    private init() {
    }
    
    enum NextResult {
    case started
    case noUploads
    case allUploadsCompleted
    case error(SyncServerError)
    }
    
    enum NextCompletion {
    case fileUploaded(SyncAttributes)
    case uploadDeletion(fileUUID:String)
    case masterVersionUpdate
    case error(SyncServerError)
    }
    
    // Starts upload of next file, if there is one. There should be no files uploading already. Only if .started is the NextResult will the completion handler be called. With a masterVersionUpdate response for NextCompletion, the MasterVersion Core Data object is updated by this method, and all the UploadFileTracker objects have been reset.
    func next(first: Bool = false, completion:((NextCompletion)->())?) -> NextResult {
        self.completion = completion
        
        var nextResult:NextResult!
        var masterVersion:MasterVersionInt!
        var nextToUpload:UploadFileTracker!
        var uploadQueue:UploadQueue!
        var deleteOnServer:Bool!
        var numberFileUploads:Int!
        var numberUploadDeletions:Int!
        
        CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
            uploadQueue = Upload.getHeadSyncQueue()
            guard uploadQueue != nil else {
                nextResult = .noUploads
                return
            }
            
            numberFileUploads =
                uploadQueue.uploadFileTrackers.filter {
                    $0.status == .notStarted && !$0.deleteOnServer
                }.count
            
            numberUploadDeletions =
                uploadQueue.uploadFileTrackers.filter {
                    $0.status == .notStarted && $0.deleteOnServer
                }.count
            
            let alreadyUploading =
                uploadQueue.uploadFileTrackers.filter {$0.status == .uploading}
            guard alreadyUploading.count == 0 else {
                Log.error("Already uploading a file!")
                nextResult = .error(.alreadyUploadingAFile)
                return
            }

            nextToUpload = uploadQueue.nextUpload()
            guard nextToUpload != nil else {
                nextResult = .allUploadsCompleted
                return
            }

            nextToUpload.status = .uploading
            deleteOnServer = nextToUpload.deleteOnServer
            
            masterVersion = Singleton.get().masterVersion
            
            do {
                try CoreData.sessionNamed(Constants.coreDataName).context.save()
            } catch (let error) {
                nextResult = .error(.coreDataError(error))
            }
        }
        
        guard nextResult == nil else {
            return nextResult!
        }
        
        if first {
            EventDesired.reportEvent(.willStartUploads(numberFileUploads: UInt(numberFileUploads), numberUploadDeletions: UInt(numberUploadDeletions)), mask: desiredEvents, delegate: delegate)
        }
        
        if deleteOnServer! {
            return uploadDeletion(nextToUpload:nextToUpload, uploadQueue:uploadQueue, masterVersion:masterVersion)
        }
        else {
            return uploadFile(nextToUpload: nextToUpload, uploadQueue: uploadQueue, masterVersion: masterVersion)
        }
    }
    
    private func uploadDeletion(nextToUpload:UploadFileTracker, uploadQueue:UploadQueue, masterVersion:MasterVersionInt) -> NextResult {

        // We need to figure out the current file version for the file we are deleting: Because, as explained in [1] in SyncServer.swift, we didn't establish the file version we were deleting earlier.
        
        var fileToDelete:ServerAPI.FileToDelete!
        
        var nextResult:NextResult?
        CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
            let entry = DirectoryEntry.fetchObjectWithUUID(uuid: nextToUpload.fileUUID)
            if entry == nil {
                nextResult = .error(.couldNotFindFileUUID(nextToUpload.fileUUID))
                return
            }
            
            if entry!.fileVersion == nil {
                nextResult = .error(.versionForFileWasNil(fileUUUID: nextToUpload.fileUUID))
                return
            }
            
            fileToDelete = ServerAPI.FileToDelete(fileUUID: nextToUpload.fileUUID, fileVersion: entry!.fileVersion!)
        }
        
        guard nextResult == nil else {
            return nextResult!
        }
        
        ServerAPI.session.uploadDeletion(file: fileToDelete, serverMasterVersion: masterVersion) { (uploadDeletionResult, error) in
        
            guard error == nil else {
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    nextToUpload.status = .notStarted
                    
                    // We already have an error, not going to worry about handling one with saveContext.
                    CoreData.sessionNamed(Constants.coreDataName).saveContext()
                }
                
                let message = "Error: \(String(describing: error))"
                Log.error(message)
                self.completion?(.error(error!))
                return
            }
            
            switch uploadDeletionResult! {
            case .success:
                var completionResult:NextCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    nextToUpload.status = .uploaded
                    
                    do {
                        try CoreData.sessionNamed(Constants.coreDataName).context.save()
                    } catch (let error) {
                        completionResult = .error(.coreDataError(error))
                        return
                    }
                    
                    completionResult = .uploadDeletion(fileUUID: nextToUpload.fileUUID)
                }

                self.completion?(completionResult!)
                
            case .serverMasterVersionUpdate(let masterVersionUpdate):
                var completionResult:NextCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    // Simplest method for now: Mark all uft's as .notStarted
                    // TODO: *4* This could be better-- performance-wise, it doesn't make sense to do all the uploads over again.
                    _ = uploadQueue.uploadFileTrackers.map { uft in
                        uft.status = .notStarted
                    }

                    Singleton.get().masterVersion = masterVersionUpdate
                    
                    do {
                        try CoreData.sessionNamed(Constants.coreDataName).context.save()
                    } catch (let error) {
                        completionResult = .error(.coreDataError(error))
                        return
                    }
                    
                    completionResult = .masterVersionUpdate
                }
                
                self.completion?(completionResult!)
            }
        }
        
        return .started
    }
    
    private func uploadFile(nextToUpload:UploadFileTracker, uploadQueue:UploadQueue,masterVersion:MasterVersionInt) -> NextResult {
        
        var file:ServerAPI.File!
        var nextResult:NextResult?
        var directoryEntry:DirectoryEntry?
        var undelete = false
        
        CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
            // 1/11/18; Determing the version to upload immediately before the upload. See https://github.com/crspybits/SyncServerII/issues/12
            
            directoryEntry = DirectoryEntry.fetchObjectWithUUID(uuid: nextToUpload.fileUUID)
            guard directoryEntry != nil else {
                nextResult = .error(.couldNotFindFileUUID(nextToUpload.fileUUID))
                return
            }
            
            if directoryEntry!.fileVersion == nil {
                nextToUpload.fileVersion = 0
            }
            else {
                nextToUpload.fileVersion = directoryEntry!.fileVersion! + 1
            }
            
            do {
                try CoreData.sessionNamed(Constants.coreDataName).context.save()
            } catch (let error) {
                nextResult = .error(.coreDataError(error))
                return
            }
            
            let mimeType = MimeType(rawValue: nextToUpload.mimeType!)!
            file = ServerAPI.File(localURL: nextToUpload.localURL! as URL!, fileUUID: nextToUpload.fileUUID, mimeType: mimeType, deviceUUID:self.deviceUUID, appMetaData: nextToUpload.appMetaData, fileVersion: nextToUpload.fileVersion)
            
            undelete = nextToUpload.uploadUndeletion
        }
        
        guard nextResult == nil else {
            return nextResult!
        }

        ServerAPI.session.uploadFile(file: file, serverMasterVersion: masterVersion, undelete: undelete) { (uploadResult, error) in
        
            guard error == nil else {
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    nextToUpload.status = .notStarted
                    
                    // Already have an error, not going to worry about reporting one for saveContext.
                    CoreData.sessionNamed(Constants.coreDataName).saveContext()
                }
                
                /* TODO: *0* Need to deal with this error:
                    1) Do retry(s)
                    2) Fail if retries don't work and put the SyncServer client interface into an error state.
                    3) Deal with other, similar, errors too, in a similar way.
                */
                let message = "Error: \(String(describing: error))"
                Log.error(message)
                self.completion?(.error(error!))
                return
            }
 
            switch uploadResult! {
            case .success(sizeInBytes: _, creationDate: let creationDate, updateDate: let updateDate):
                var completionResult:NextCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    nextToUpload.status = .uploaded
                    let mimeType = MimeType(rawValue: nextToUpload.mimeType!)!

                    // 1/27/18; See [2] below.
                    var attr = SyncAttributes(fileUUID: nextToUpload.fileUUID, mimeType:mimeType, creationDate: creationDate, updateDate: updateDate)
                    
                    // `nextToUpload.appMetaData` may be nil because the client isn't making a change to the appMetaData.
                    var appMetaData:String?
                    if let amd = nextToUpload.appMetaData {
                        appMetaData = amd
                    }
                    else {
                        // See if the directory entry has any appMetaData
                        if let dirEnt = DirectoryEntry.fetchObjectWithUUID(uuid: nextToUpload.fileUUID), let amd = dirEnt.appMetaData {
                            appMetaData = amd
                        }
                    }
                    
                    attr.appMetaData = appMetaData
                    completionResult = .fileUploaded(attr)
                }
                
                self.completion?(completionResult!)

            case .serverMasterVersionUpdate(let masterVersionUpdate):
                var completionResult:NextCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    // Simplest method for now: Mark all uft's as .notStarted
                    // TODO: *4* This could be better-- performance-wise, it doesn't make sense to do all the uploads over again.
                    _ = uploadQueue.uploadFileTrackers.map { uft in
                        uft.status = .notStarted
                    }

                    Singleton.get().masterVersion = masterVersionUpdate
                    
                    do {
                        try CoreData.sessionNamed(Constants.coreDataName).context.save()
                    } catch (let error) {
                        completionResult = .error(.coreDataError(error))
                        return
                    }
                    
                    completionResult = .masterVersionUpdate
                }
                
                self.completion?(completionResult!)
            }
        }
        
        return .started
    }
    
    enum DoneUploadsCompletion {
    case doneUploads(numberTransferred: Int64)
    case masterVersionUpdate
    case error(SyncServerError)
    }
    
    func doneUploads(completion:((DoneUploadsCompletion)->())?) {
        var masterVersion:MasterVersionInt!
        CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
            masterVersion = Singleton.get().masterVersion
        }
        
        ServerAPI.session.doneUploads(serverMasterVersion: masterVersion) { (result, error) in
            guard error == nil else {
                completion?(.error(error!))
                return
            }

            switch result! {
            case .success(numberUploadsTransferred: let numberTransferred):
                var completionResult:DoneUploadsCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    // Master version was incremented on the server as part of normal doneUploads operation. Update ours locally.
                    Singleton.get().masterVersion = masterVersion + MasterVersionInt(1)
                    
                    do {
                        try CoreData.sessionNamed(Constants.coreDataName).context.save()
                    } catch (let error) {
                        completionResult = .error(.coreDataError(error))
                        return
                    }
                    
                    completionResult = .doneUploads(numberTransferred: numberTransferred)
                }
                
                completion?(completionResult!)
                
            case .serverMasterVersionUpdate(let masterVersionUpdate):
                var completionResult:DoneUploadsCompletion?
                CoreData.sessionNamed(Constants.coreDataName).performAndWait() {
                    guard let uploadQueue = Upload.getHeadSyncQueue() else {
                        completionResult = .error(.generic("Failed on getHeadSyncQueue"))
                        return
                    }
                    
                    // Simplest method for now: Mark all uft's as .notStarted
                    // TODO: *4* This could be better-- performance-wise, it doesn't make sense to do all the uploads over again.
                    _ = uploadQueue.uploadFileTrackers.map { uft in
                        uft.status = .notStarted
                    }

                    Singleton.get().masterVersion = masterVersionUpdate
                    
                    do {
                        try CoreData.sessionNamed(Constants.coreDataName).context.save()
                    } catch (let error) {
                        completionResult = .error(.coreDataError(error))
                        return
                    }
                                        
                    completionResult = .masterVersionUpdate
                }
                
                completion?(completionResult!)
            }
        }
    }
}

/* 1/27/18; [2]. For some reason, up until now, I'd been assigning the directory entry from the uft file version right here (at [2] above in the code):

    directoryEntry!.fileVersion = nextToUpload.fileVersion

    HOWEVER, the upload isn't actually done until the DoneUploads
    succeeds *after* the upload. I'm focused on this right now because I just got an error because of this. The situation went like this:
    
    1) A file upload occurred (device 1)
    2) Two successive DoneUploads occurred (device 2, and then device 1, for the same user data)
    3) The second DoneUploads (trying to complete the file upload in 1)) fails because of the master version update from the Device 2 DoneUploads
    4) Device 1 retries its file upload, which makes the attempt with file version 1 because the directory entry had been assigned version 0 already.
    5) That file upload failed with a server error "File is new, but file version being uploaded (Optional(1)) is not 0".

    We'd been doing that fileVersion update in [1] in SyncManager.swift previously, so should be safe in just removing the assignment here.
*/
