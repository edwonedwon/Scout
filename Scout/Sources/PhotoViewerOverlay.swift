import SwiftUI
import ScoutKit

struct PhotoViewerOverlay: View {
    @ObservedObject private var viewer = PhotoViewerState.shared
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Backdrop — tap anywhere outside the scroll row to dismiss
            Color.black.opacity(0.88)
                .ignoresSafeArea()
                .onTapGesture { viewer.dismiss() }

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    if !viewer.images.isEmpty {
                        Text("\(viewer.selectedIndex + 1) / \(viewer.images.count)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.white.opacity(0.7))
                            .monospacedDigit()
                    }
                    Spacer()
                    Button(action: viewer.dismiss) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

                // Photo strip — paging scroll
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(Array(viewer.images.enumerated()), id: \.offset) { idx, img in
                                AsyncImage(url: img.url) { phase in
                                    switch phase {
                                    case .success(let image):
                                        image
                                            .resizable()
                                            .aspectRatio(contentMode: .fit)
                                    case .failure:
                                        Image(systemName: "photo")
                                            .font(.system(size: 48))
                                            .foregroundStyle(.white.opacity(0.3))
                                    default:
                                        ProgressView()
                                            .tint(.white)
                                    }
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .containerRelativeFrame(.horizontal)
                                .id(idx)
                                // Prevent taps on the photo from dismissing the backdrop
                                .contentShape(Rectangle())
                                .onTapGesture {}
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: Binding(
                        get: { viewer.selectedIndex },
                        set: { if let v = $0 { viewer.selectedIndex = v } }
                    ))
                    .onChange(of: viewer.selectedIndex) { _, idx in
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(idx, anchor: .center)
                        }
                    }
                    .onAppear {
                        proxy.scrollTo(viewer.selectedIndex, anchor: .center)
                        focused = true
                    }
                }

                // Bottom: dots + arrows + location info
                VStack(spacing: 10) {
                    // Dot indicators (up to 10)
                    if viewer.images.count > 1 {
                        HStack(spacing: 6) {
                            ForEach(0..<min(viewer.images.count, 10), id: \.self) { idx in
                                Circle()
                                    .fill(idx == viewer.selectedIndex ? Color.white : Color.white.opacity(0.35))
                                    .frame(width: idx == viewer.selectedIndex ? 7 : 5, height: idx == viewer.selectedIndex ? 7 : 5)
                                    .animation(.spring(duration: 0.2), value: viewer.selectedIndex)
                                    .onTapGesture { viewer.selectedIndex = idx }
                            }
                        }
                    }

                    // Arrow buttons
                    HStack(spacing: 32) {
                        Button {
                            viewer.previous()
                        } label: {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .opacity(viewer.selectedIndex > 0 ? 1 : 0.2)
                        .disabled(viewer.selectedIndex == 0)

                        Button {
                            viewer.next()
                        } label: {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                        .opacity(viewer.selectedIndex < viewer.images.count - 1 ? 1 : 0.2)
                        .disabled(viewer.selectedIndex >= viewer.images.count - 1)
                    }

                    // Location info bar
                    if let loc = viewer.location {
                        locationInfoBar(loc)
                    }
                }
                .padding(.top, 12)
                .padding(.bottom, 20)
            }
        }
        .focusable()
        .focused($focused)
        .onKeyPress(.leftArrow)  { viewer.previous(); return .handled }
        .onKeyPress(.rightArrow) { viewer.next();     return .handled }
        .onKeyPress(.escape)     { viewer.dismiss();  return .handled }
    }

    @ViewBuilder
    private func locationInfoBar(_ loc: ScoutLocation) -> some View {
        VStack(spacing: 6) {
            Text(loc.name)
                .font(.headline)
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            if !loc.description.isEmpty {
                Text(loc.description)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                if viewer.onViewOnMap != nil {
                    Button {
                        viewer.dismiss()
                        viewer.onViewOnMap?(loc)
                    } label: {
                        Label("Show on Map", systemImage: "map")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }

                if let mapsURL = loc.googleMapsURL {
                    Link(destination: mapsURL) {
                        Label("Google Maps", systemImage: "arrow.up.right.square")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }

                if let sourceURL = loc.sourceURL {
                    Link(destination: sourceURL) {
                        Label("Source", systemImage: "link")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
    }
}
