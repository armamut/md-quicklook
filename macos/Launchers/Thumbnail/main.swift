// The thumbnail extension's executable. Its entry point is NSExtensionMain
// itself (set at link time): for this extension type, ExtensionKit calls the
// executable's main() again from within NSExtensionMain. Everything else is in
// the shared libMDQuickLookCore.dylib, which this executable links.
import Foundation
