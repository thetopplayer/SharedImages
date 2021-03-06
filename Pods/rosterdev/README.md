# rosterdev

## Example

To run the example project, clone the repo, and run `pod install` from the Example directory first.

## Requirements

## Installation

rosterdev is available through [CocoaPods](http://cocoapods.org). To install
it, add the following line to your Podfile:

```ruby
pod 'rosterdev', '~> 0.1'
```

The intent is that these developer functions will only be available in debug builds of your app. To accomplish this in Swift, [create a `DEBUG` `OTHER_SWIFT_FLAGS` for your debug build](./docs/debugFlag.png).

In your code, do:

```
import rosterdev
```

You will also need to enable the developer dashboard to be displayed. One way to do this is via a shake gesture. [See the example here](Example/rosterdev/AppDelegate.swift):

```
#if DEBUG
extension UIWindow {
    override open func motionBegan(_ motion: UIEventSubtype, with event: UIEvent?) {
        if motion == .motionShake {
            if let rootVC = UIApplication.shared.keyWindow?.rootViewController {
                RosterDevVC.show(fromViewController: rootVC, rowContents: [], options: .all)
            }
        }
    }
}
#endif
```

In the above example, if you want to put additional rows of your own design into the developer dashboard, you'll need to provide a non-empty list to the rowContents: parameter.

The class `DebugDashboardData` in the Example code provides an example of this:

```
class DebugDashboardData {
    private init() {
    }
    
    static let session = DebugDashboardData()
    
    var debugDashboardExampleSection: [RosterDevRowContents] = {
        var useDev = RosterDevRowContents(name: "Use staging environment", action: { parentVC in
            // Need to do something to setup staging environment
        })
        var useProd = RosterDevRowContents(name: "Use prod environment", action: { parentVC in
            // Need to do something to setup prod environment
        })
        
        return [useDev, useProd]
    }()
    
    func sections() -> [[RosterDevRowContents]] {
        return [debugDashboardExampleSection]
    }
}
```

To use this class, use `DebugDashboardData.session.sections()` to the `rowContents` parameter.

If you are doing test injection, you will need:

```
#if DEBUG
    TestCases.setup()
#endif
```

in your AppDelegate. [See the example here](Example/rosterdev/AppDelegate.swift):

```
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplicationLaunchOptionsKey: Any]?) -> Bool {
        // Override point for customization after application launch.
#if DEBUG
    TestCases.setup()
#endif
        return true
    }
```

## Author

crspybits, chris.prince@withroster.com

## License

rosterdev is available under the MIT license. See the LICENSE file for more info.
