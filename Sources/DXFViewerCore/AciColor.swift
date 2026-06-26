import Foundation
import CoreGraphics

// Shared ACI → CGColor lookup. The SwiftUI executable wraps these in `Color` for the
// live canvas; the headless renderer uses them directly.
public func aciCG(_ aci: Int) -> CGColor {
    switch aci {
    case 1: return CGColor(srgbRed: 0.85, green: 0.10, blue: 0.10, alpha: 1)
    case 2: return CGColor(srgbRed: 0.70, green: 0.60, blue: 0.05, alpha: 1)
    case 3: return CGColor(srgbRed: 0.00, green: 0.58, blue: 0.00, alpha: 1)
    case 4: return CGColor(srgbRed: 0.00, green: 0.55, blue: 0.65, alpha: 1)
    case 5: return CGColor(srgbRed: 0.10, green: 0.10, blue: 0.85, alpha: 1)
    case 6: return CGColor(srgbRed: 0.70, green: 0.00, blue: 0.70, alpha: 1)
    case 8: return CGColor(srgbRed: 0.45, green: 0.45, blue: 0.50, alpha: 1)
    case 9: return CGColor(srgbRed: 0.60, green: 0.60, blue: 0.66, alpha: 1)
    default: return CGColor(srgbRed: 0.12, green: 0.13, blue: 0.16, alpha: 1)
    }
}
