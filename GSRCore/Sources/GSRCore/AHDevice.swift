import Foundation

/// The only devices this software drives.
public enum AHDeviceKind: String, Equatable {
    case gsr24 = "GS-R24"
    case zedr16 = "ZED-R16"
}

public extension DiceReport {
    /// Unit_Spec_ID that the vendor driver matches (1220). For DICE units this is the vendor OUI.
    static let allenHeathSpecID: UInt32 = 0x0004C4

    /// Identifies an Allen & Heath console interface, or nil with no guess for anything else.
    /// Rule taken from the vendor driver: TCAT category 0x04, product 0 = ZED-R16, product 1 = GS-R24.
    /// The unit must also look like Allen & Heath: Unit_Spec_ID 1220, a GUID whose OUI is 0x0004C4,
    /// or a vendor name containing "Allen".
    var ahKind: AHDeviceKind? { ahCheck().kind }

    /// Same check with the reason when it fails, for the diagnostics screen.
    func ahCheck() -> (kind: AHDeviceKind?, reason: String) {
        let isAH = unitSpecID == DiceReport.allenHeathSpecID
            || tcatOUI == DiceReport.allenHeathSpecID
            || vendor.range(of: "allen", options: .caseInsensitive) != nil
        guard isAH else {
            return (nil, "Pas un appareil Allen & Heath (fabricant \"\(vendor)\", Unit_Spec_ID \(unitSpecID.map { String(format: "0x%06X", $0) } ?? "inconnu")).")
        }
        guard tcatCategory == 0x04 else {
            return (nil, "Catégorie TCAT \(tcatCategory.map { String(format: "0x%02X", $0) } ?? "inconnue") au lieu de 0x04 (DICE standard).")
        }
        switch tcatProduct {
        case 0: return (.zedr16, "ZED-R16")
        case 1: return (.gsr24, "GS-R24")
        default: return (nil, "Produit TCAT \(tcatProduct.map(String.init) ?? "inconnu") : ni ZED-R16 (0) ni GS-R24 (1).")
        }
    }
}
