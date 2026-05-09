import SwiftUI

struct SelectionAccessoryLayerView<NodeData: Sendable & Hashable>: View {

    let store: FlowStore<NodeData>
    let canvasSize: CGSize
    let layer: SelectionAccessoryLayer
    let builders: [SelectionAccessoryBuilder<NodeData>]

    var body: some View {
        let layerBuilders = builders.enumerated().filter { _, builder in
            builder.layer == layer
        }

        if !layerBuilders.isEmpty,
           let context = SelectionContextResolver.resolve(store: store, canvasSize: canvasSize) {
            ZStack(alignment: .topLeading) {
                ForEach(Array(layerBuilders), id: \.offset) { entry in
                    entry.element.content(context)
                }
            }
            .frame(width: canvasSize.width, height: canvasSize.height, alignment: .topLeading)
            .allowsHitTesting(layer == .overlay)
        }
    }
}
