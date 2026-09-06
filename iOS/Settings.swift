import SwiftUI

/// Valori predefiniti = impostazioni del trackpad del Mac di Michele (letti da
/// com.apple.AppleMultitouchTrackpad il 2026-09-06).
final class Settings: ObservableObject {
    @AppStorage("sensitivity") var sensitivity: Double = 1.8
    @AppStorage("acceleration") var acceleration: Bool = true
    @AppStorage("tapToClick") var tapToClick: Bool = true          // Clicking = 1
    @AppStorage("twoFingerRightClick") var twoFingerRightClick: Bool = true  // TrackpadRightClick = 1
    @AppStorage("tapDrag") var tapDrag: Bool = false               // Dragging = 0
    @AppStorage("holdToDrag") var holdToDrag: Bool = true          // tieni fermo un dito = clic tenuto, poi trascina
    @AppStorage("showDebug") var showDebug: Bool = false
    @AppStorage("threeFingerDrag") var threeFingerDrag: Bool = true // TrackpadThreeFingerDrag = 1
    @AppStorage("naturalScroll") var naturalScroll: Bool = true    // swipescrolldirection = 1
    @AppStorage("scrollSpeed") var scrollSpeed: Double = 1.0
    @AppStorage("momentum") var momentum: Bool = true              // TrackpadMomentumScroll = 1
    @AppStorage("pinchZoom") var pinchZoom: Bool = true            // TrackpadPinch = 1
    @AppStorage("fourFingerSpaces") var fourFingerSpaces: Bool = true       // FourFingerHorizSwipe = 2
    @AppStorage("fourFingerMissionControl") var fourFingerMissionControl: Bool = true // FourFingerVertSwipe = 2
    @AppStorage("fourFingerAppExpose") var fourFingerAppExpose: Bool = false // showAppExposeGestureEnabled = 0
    @AppStorage("fourFingerPinch") var fourFingerPinch: Bool = true         // TrackpadFourFingerPinchGesture = 2
    @AppStorage("haptics") var haptics: Bool = true
    @AppStorage("padWidth") var padWidth: Double = 0
    @AppStorage("padHeight") var padHeight: Double = 0
}
