//
//  SettingsVC.swift
//  SharedImages
//
//  Created by Christopher G Prince on 8/19/17.
//  Copyright © 2017 Spastic Muffin, LLC. All rights reserved.
//

import Foundation
import UIKit
import SMCoreLib

class SettingsVC : UIViewController {
    @IBOutlet weak var imageOrderSwitch: UISwitch!
    @IBOutlet weak var versionAndBuild: UILabel!
    
    var vb:String {
        if let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String,
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String {
            return version + "/" + build
        }
        else {
            return ""
        }
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        
        versionAndBuild.text = vb
        versionAndBuild.sizeToFit()
        
        imageOrderSwitch.isOn = ImageExtras.currentSortingOrder.stringValue == SortingOrder.newerAtTop.rawValue
    }
    
    @IBAction func imageOrderSwitchAction(_ imageOrderSwitch: UISwitch) {
        if imageOrderSwitch.isOn {
            ImageExtras.currentSortingOrder.stringValue = SortingOrder.newerAtTop.rawValue
        }
        else {
            ImageExtras.currentSortingOrder.stringValue = SortingOrder.newerAtBottom.rawValue
        }
    }
    
    @IBAction func emailLogAction(_ sender: Any) {
        Log.msg("Log.logFileURL: \(Log.logFileURL!)")
        
        guard let logFileData = try? Data(contentsOf: Log.logFileURL!, options: NSData.ReadingOptions()) else {
            SMCoreLib.Alert.show(fromVC: self, withTitle: "Alert!", message: "No log file present in app!")
            return
        }
        
        guard let email = SMEmail(parentViewController: self) else {
            // SMEmail gives the user an alert about this.
            return
        }
        
        email.addAttachmentData(logFileData, mimeType: "text/plain", fileName: Log.logFileName)

        let versionDetails = SMEmail.getVersionDetails(for: "SharedImages")!
        email.setMessageBody(versionDetails, isHTML: false)
        email.setSubject("Log for developer of SharedImages")
        email.setToRecipients(["chris@SpasticMuffin.biz"])
        email.show()
    }
}
