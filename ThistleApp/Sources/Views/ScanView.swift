import SwiftUI
import VisionKit

struct ScanView: View {
    @EnvironmentObject private var store: AppStore
    @State private var scannedCode: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Barcode Scan")
                    .font(.largeTitle.weight(.bold))
                Text("Use the camera on a supported device, or type a barcode to simulate scan results while building the product catalog.")
                    .foregroundStyle(.secondary)

                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    BarcodeScannerView(scannedCode: $scannedCode)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                    unsupportedView
                }

                manualLookup

                if let resolvedCode = scannedCode ?? (!store.manualBarcode.isEmpty ? store.manualBarcode : nil) {
                    lookupResult(for: resolvedCode)
                }
            }
            .padding()
        }
        .navigationTitle("Scan")
    }

    private var unsupportedView: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(Color(.secondarySystemBackground))
            .frame(height: 220)
            .overlay {
                VStack(spacing: 8) {
                    Image(systemName: "camera.metering.unknown")
                        .font(.largeTitle)
                    Text("Live scanning needs a physical device with VisionKit barcode support.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
            }
    }

    private var manualLookup: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Manual barcode")
                .font(.headline)
            TextField("Enter UPC / EAN", text: $store.manualBarcode)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)
        }
        .padding()
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func lookupResult(for code: String) -> some View {
        if let product = store.productForBarcode(code) {
            NavigationLink {
                ProductDetailView(product: product)
            } label: {
                ProductCard(product: product, analysis: store.analysis(for: product))
            }
            .buttonStyle(.plain)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text("No local match for \(code)")
                    .font(.headline)
                Text("Next backend step: resolve the barcode through a UPC/product API, then cache the normalized product locally.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 20))
        }
    }
}

struct BarcodeScannerView: UIViewControllerRepresentable {
    @Binding var scannedCode: String?

    func makeCoordinator() -> Coordinator {
        Coordinator(scannedCode: $scannedCode)
    }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: true,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        try? controller.startScanning()
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        @Binding var scannedCode: String?

        init(scannedCode: Binding<String?>) {
            _scannedCode = scannedCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            if case .barcode(let barcode) = item {
                scannedCode = barcode.payloadStringValue
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard let first = addedItems.first else { return }
            if case .barcode(let barcode) = first {
                scannedCode = barcode.payloadStringValue
            }
        }
    }
}
