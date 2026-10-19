// WizRec — free, open-source screen recorder & editor by Devs Wizard.
// M1: read-only player for .cmproj / .tscproj projects.
import AppKit
import PlayerKit
import WizRecAssets

AppEnvironment.preferences = AppPreferences.load(from: .standard)
AppEnvironment.options = AppEnvironment.preferences.launchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
// Opt-in, local-only crash reports (Settings ▸ Privacy).
if AppEnvironment.preferences.crashLogsEnabled { CrashLog.setEnabled(true) }
// WizRec's own OFL fonts, process-scoped, so callout text finds them.
_ = AssetFonts.registerAll()

// We open command-line paths ourselves; stop AppKit from treating every argument
// (option values included) as a file to open.
UserDefaults.standard.register(defaults: ["NSTreatUnknownArgumentsAsOpen": "NO"])

// Must be created before NSApplication instantiates the default controller.
_ = WizRecDocumentController()

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.mainMenu = MainMenu.make()
app.run()
