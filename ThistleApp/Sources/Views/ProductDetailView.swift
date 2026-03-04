import SwiftUI

struct ProductDetailView: View {
    @EnvironmentObject private var store: AppStore
    var product: Product
    @State private var servings = 1.0

    var body: some View {
        let currentProduct = store.product(withID: product.id) ?? product
        let analysis = store.analysis(for: currentProduct)
        let proposal = proposal(for: currentProduct)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentProduct.name)
                                .font(.largeTitle.weight(.bold))
                            Text(currentProduct.brand)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        RatingBadge(rating: analysis.rating)
                    }

                    Text(analysis.summary)
                        .font(.headline)
                        .foregroundStyle(analysis.rating.color)

                    Button {
                        Task { await store.enrich(product: currentProduct, scope: .all) }
                    } label: {
                        if store.isDeepSearchActive(productID: currentProduct.id) {
                            HStack(spacing: 8) {
                                ProgressView()
                                Text("BETA: Filling In/Updating...")
                            }
                        } else {
                            Text("BETA: Fill In/Update With Deep Search")
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(store.isDeepSearching)

                    storesSection(for: currentProduct)

                    macrosSection(for: currentProduct)
                }
                .padding()
                .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))

                VStack(alignment: .leading, spacing: 12) {
                    Text("Serving")
                        .font(.headline)
                    Stepper(value: $servings, in: 0.5...6, step: 0.5) {
                        Text("\(servings.formatted()) x \(currentProduct.servingDescription)")
                    }
                    Button("Log Food") {
                        store.log(product: currentProduct, servings: servings)
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))

                IngredientsSection(product: currentProduct, analysis: analysis)
                    .contextMenu {
                        Button("BETA: Fill In/Update Ingredients") {
                            Task { await store.enrich(product: currentProduct, scope: .ingredients) }
                        }
                    }

                if let proposal {
                    proposalSection(proposal)
                }

                if store.isDeepSearchActive(productID: currentProduct.id) || !store.deepSearchDebugLog.isEmpty {
                    debugSection
                }
            }
            .padding()
        }
        .background(ThistleTheme.canvas.ignoresSafeArea())
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func storesSection(for product: Product) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Available At")
                .font(.headline)
            Text(product.stores.isEmpty ? "No store data yet." : product.stores.joined(separator: ", "))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .contextMenu {
            Button("BETA: Fill In/Update Stores") {
                Task { await store.enrich(product: product, scope: .stores) }
            }
        }
    }

    private func macrosSection(for product: Product) -> some View {
        MacroSummaryView(nutrition: product.nutrition * servings)
            .contextMenu {
                Button("BETA: Fill In/Update Macros") {
                    Task { await store.enrich(product: product, scope: .macros) }
                }
            }
    }

    private var debugSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Deep Search Debug")
                    .font(.headline)
                if store.isDeepSearchActive(productID: product.id) {
                    ProgressView()
                }
            }

            if store.deepSearchDebugLog.isEmpty {
                Text("Waiting for deep search updates...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(store.deepSearchDebugLog.enumerated()), id: \.offset) { _, entry in
                    Text(entry)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }

    private func proposal(for product: Product) -> DeepSearchProposal? {
        guard let proposal = store.pendingDeepSearchProposal, proposal.productID == product.id else {
            return nil
        }
        return proposal
    }

    private func proposalSection(_ proposal: DeepSearchProposal) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Deep Search Review")
                .font(.headline)

            Text("Does this look like the right update info?")
                .font(.subheadline)

            Text("Confidence \(proposal.confidenceScore)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if !proposal.confidenceReasons.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(proposal.confidenceReasons, id: \.self) { reason in
                        Text(reason)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(proposal.changedFields) { diff in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(diff.label)
                                .font(.subheadline.weight(.semibold))
                            if diff.addsMissingData {
                                Text("fills missing")
                                    .font(.caption2.weight(.bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(ThistleTheme.primaryGreen.opacity(0.15), in: Capsule())
                            }
                        }
                        Text("Current: \(diff.oldValue)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Update: \(diff.newValue)")
                            .font(.caption)
                    }
                    if diff.id != proposal.changedFields.last?.id {
                        Divider()
                    }
                }
            }

            HStack(spacing: 12) {
                Button("Apply Update") {
                    store.approvePendingDeepSearchProposal()
                }
                .buttonStyle(.borderedProminent)

                Button("Reject") {
                    store.rejectPendingDeepSearchProposal()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .background(ThistleTheme.card, in: RoundedRectangle(cornerRadius: 20))
    }
}
