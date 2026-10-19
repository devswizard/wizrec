import Testing
import CoreGraphics
@testable import RenderEngine

@Test func emptyPlanHasNoFrameRequests() {
    let plan = RenderPlan(time: 0, canvasSize: CGSize(width: 1920, height: 1080), background: RGBA(0, 0, 0), layers: [])
    #expect(plan.frameRequests.isEmpty)
}
