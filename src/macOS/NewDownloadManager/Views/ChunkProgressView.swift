import SwiftUI

struct ChunkProgressView: View {
    let chunks: [ChunkInfo]

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(chunks) { chunk in
                    let widthRatio = chunks.count > 0
                        ? CGFloat(chunk.totalBytes) / CGFloat(totalBytes)
                        : 1.0 / CGFloat(max(chunks.count, 1))

                    ZStack(alignment: .leading) {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.2))

                        Rectangle()
                            .fill(chunkColor(for: chunk))
                            .frame(width: max(0, (geometry.size.width * widthRatio - CGFloat(chunks.count - 1)) * chunk.progress))
                    }
                    .frame(width: max(0, geometry.size.width * widthRatio - CGFloat(chunks.count - 1) / CGFloat(chunks.count)))
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    private var totalBytes: Int64 {
        chunks.reduce(0) { $0 + $1.totalBytes }
    }

    private func chunkColor(for chunk: ChunkInfo) -> Color {
        if chunk.isCompleted {
            return .green
        }
        let colors: [Color] = [.blue, .purple, .orange, .cyan, .pink, .yellow, .mint, .indigo]
        return colors[chunk.id % colors.count]
    }
}
