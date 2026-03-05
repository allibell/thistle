import SwiftUI
import VisionKit

struct ScanView: View {
    @EnvironmentObject private var store: AppStore
    @State private var scannedCode: String?
    @State private var lookupTask: Task<Void, Never>?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    BarcodeScannerView(scannedCode: $scannedCode)
                        .frame(height: 320)
                        .clipShape(RoundedRectangle(cornerRadius: 24))
                } else {
                    unsupportedView
                }

                manualLookup

                if store.isLookingUpBarcode {
                    ProgressView("Looking up barcode...")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                if let resolvedProduct = store.barcodeLookupResult {
                    NavigationLink {
                        ProductDetailView(product: resolvedProduct)
                    } label: {
                        ProductCard(product: resolvedProduct, analysis: store.analysis(for: resolvedProduct))
                    }
                    .buttonStyle(.plain)

                    HStack {
                        Spacer()
                        Button("Scan Another") {
                            resetForFreshScan(clearManualBarcode: false)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                } else if let resolvedCode = scannedCode ?? (!store.manualBarcode.isEmpty ? store.manualBarcode : nil) {
                    lookupResult(for: resolvedCode)
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .thistleNavigationTitle("Scan")
        .refreshable {
            resetForFreshScan(clearManualBarcode: true)
        }
        .onAppear {
            if store.selectedTab == .scan {
                resetForFreshScan(clearManualBarcode: false)
            }
        }
        .onChange(of: scannedCode) { _, newValue in
            guard let newValue else { return }
            lookupTask?.cancel()
            lookupTask = Task {
                await store.lookupBarcode(newValue)
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    scannedCode = nil
                }
            }
        }
        .onChange(of: store.selectedTab) { _, newValue in
            guard newValue == .scan else { return }
            resetForFreshScan(clearManualBarcode: false)
        }
        .onDisappear {
            lookupTask?.cancel()
            lookupTask = nil
        }
    }

    private func resetForFreshScan(clearManualBarcode: Bool) {
        lookupTask?.cancel()
        lookupTask = nil
        scannedCode = nil
        store.resetBarcodeLookupState(clearManualBarcode: clearManualBarcode)
    }

    private var unsupportedView: some View {
        RoundedRectangle(cornerRadius: 24)
            .fill(ThistleTheme.card)
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
            Button("Lookup Barcode") {
                Task { await store.lookupBarcode(store.manualBarcode) }
            }
            .buttonStyle(.borderedProminent)
            .disabled(store.manualBarcode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isLookingUpBarcode)
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    @ViewBuilder
    private func lookupResult(for code: String) -> some View {
        if let product = store.productForBarcode(code) {
            ProductCard(product: product, analysis: store.analysis(for: product))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(store.barcodeLookupError ?? "No cached match for \(code)")
                    .font(.headline)
                Text("Try barcode lookup to search the online catalog and cache the normalized product locally.")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
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
        private var lastScannedPayload: String?
        private var lastScannedAt: Date = .distantPast

        init(scannedCode: Binding<String?>) {
            _scannedCode = scannedCode
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didTapOn item: RecognizedItem
        ) {
            if case .barcode(let barcode) = item {
                submitBarcodePayload(barcode.payloadStringValue)
            }
        }

        func dataScanner(
            _ dataScanner: DataScannerViewController,
            didAdd addedItems: [RecognizedItem],
            allItems: [RecognizedItem]
        ) {
            guard let first = addedItems.first else { return }
            if case .barcode(let barcode) = first {
                submitBarcodePayload(barcode.payloadStringValue)
            }
        }

        private func submitBarcodePayload(_ payload: String?) {
            guard let payload, !payload.isEmpty else { return }
            let now = Date()
            if lastScannedPayload == payload, now.timeIntervalSince(lastScannedAt) < 0.8 {
                return
            }
            lastScannedPayload = payload
            lastScannedAt = now

            scannedCode = nil
            DispatchQueue.main.async {
                self.scannedCode = payload
            }
        }
    }
}
