import SwiftUI
import MapKit
import ScoutKit
import CoreVideo
import Combine
#if os(macOS)
import AppKit
#endif

// MARK: - Boundary name language

enum BoundaryNameLanguage: String, CaseIterable, RawRepresentable {
    case japanese, english, both
    var label: String {
        switch self { case .japanese: "Japanese"; case .english: "English"; case .both: "Both" }
    }
}

// MARK: - Boundary polygon (MKPolygon subclass carries color + name)

final class BoundaryPolygon: MKPolygon {
    var boundaryName: String = ""
    var boundaryNameEn: String? = nil
    var colorIndex: Int = 0

    static let palette: [CGColor] = [
        CGColor(red: 0.28, green: 0.53, blue: 0.90, alpha: 1),
        CGColor(red: 0.22, green: 0.71, blue: 0.55, alpha: 1),
        CGColor(red: 0.94, green: 0.57, blue: 0.18, alpha: 1),
        CGColor(red: 0.76, green: 0.32, blue: 0.64, alpha: 1),
        CGColor(red: 0.87, green: 0.77, blue: 0.11, alpha: 1),
        CGColor(red: 0.84, green: 0.28, blue: 0.28, alpha: 1),
        CGColor(red: 0.26, green: 0.63, blue: 0.30, alpha: 1),
        CGColor(red: 0.55, green: 0.40, blue: 0.78, alpha: 1),
        CGColor(red: 0.15, green: 0.62, blue: 0.74, alpha: 1),
        CGColor(red: 0.91, green: 0.38, blue: 0.54, alpha: 1),
        CGColor(red: 0.57, green: 0.74, blue: 0.30, alpha: 1),
        CGColor(red: 0.78, green: 0.51, blue: 0.20, alpha: 1),
    ]

    var baseColor: CGColor { BoundaryPolygon.palette[colorIndex % BoundaryPolygon.palette.count] }
}

// MARK: - Boundary label annotation

final class BoundaryLabelAnnotation: NSObject, MKAnnotation {
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let colorIndex: Int
    init(_ name: String, at coordinate: CLLocationCoordinate2D, colorIndex: Int) {
        self.coordinate = coordinate
        self.title = name
        self.colorIndex = colorIndex
    }
}

#if os(macOS)
// MARK: - Boundary label annotation view

final class BoundaryLabelView: MKAnnotationView {
    static let reuseID = "boundaryLabel"

    var labelText: String = "" { didSet { needsDisplay = true; updateLabelSize() } }
    var colorIndex: Int = 0 { didSet { needsDisplay = true } }
    var fontSize: CGFloat = 17 { didSet { needsDisplay = true; updateLabelSize() } }

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        canShowCallout = false
    }
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: CGPoint) -> NSView? { nil }

    private func updateLabelSize() {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let size = (labelText as NSString).size(withAttributes: [.font: font])
        frame.size = CGSize(width: ceil(size.width) + 10, height: ceil(size.height) + 6)
    }

    override func draw(_ rect: NSRect) {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.9)
        shadow.shadowBlurRadius = 4
        shadow.shadowOffset = CGSize(width: 0, height: -1)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white,
            .shadow: shadow,
            .strokeColor: NSColor.black.withAlphaComponent(0.5),
            .strokeWidth: -1.5,
        ]
        (labelText as NSString).draw(in: bounds.insetBy(dx: 5, dy: 3), withAttributes: attrs)
    }
}
#endif

// MARK: - Menu action helper (macOS)

#if os(macOS)
final class MenuAction: NSObject {
    let closure: () -> Void
    init(_ closure: @escaping () -> Void) { self.closure = closure }
    @objc func invoke() { closure() }
}
#endif
