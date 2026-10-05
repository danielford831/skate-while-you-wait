// skate-gpu: the Skate While You Wait window. SceneKit on Metal, launched by the
// skate mod. argv[1] is a JSON status file the mod rewrites (Claude's state,
// records, a raise counter); the game prints `RUN {"score":..,"bones":..}`
// lines on stdout for the mod to keep.

import Cocoa
import SceneKit
import SpriteKit
import simd

// MARK: - Status from the mod

struct Status: Decodable, Equatable {
    var working = false
    var activity = ""
    var tools = 0
    var best = 0
    var bones = 0
    var raise = 0
}

final class StatusFeed {
    private let path: String
    private let lock = NSLock()
    private var current = Status()
    var onRaise: (() -> Void)?

    init(path: String) { self.path = path }

    var status: Status {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func start() {
        poll()
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.poll() }
    }

    private func poll() {
        guard let data = FileManager.default.contents(atPath: path),
              let next = try? JSONDecoder().decode(Status.self, from: data) else { return }
        lock.lock()
        let raised = next.raise != current.raise && current.raise != 0
        current = next
        lock.unlock()
        if raised { onRaise?() }
    }
}

// MARK: - Simulation (units: 1 = 0.6 m; seconds)

let S: Float = 0.6 // metres per sim unit

struct Trick { let name: String; let duration: Float; let pts: Int }

let TRICKS: [String: Trick] = [
    "left": Trick(name: "Kickflip", duration: 0.35, pts: 100),
    "right": Trick(name: "Heelflip", duration: 0.35, pts: 100),
    "down": Trick(name: "Indy Grab", duration: 0.45, pts: 150),
    "up": Trick(name: "Tre Flip", duration: 0.55, pts: 250),
]

let BONES = ["left femur", "right femur", "pelvis", "tailbone", "left wrist", "right wrist",
             "collarbone", "two ribs", "skull (a bit)", "left ankle", "right tibia", "nose"]

enum Mode { case title, ride, air, grind, bail }
enum Kind { case rail, kicker, cone, gap, token }

final class Ob {
    let kind: Kind
    let x: Float
    let len: Float
    let h: Float
    let label: String
    var taken = false
    var node: SCNNode?
    init(kind: Kind, x: Float, len: Float, h: Float = 0, label: String = "") {
        self.kind = kind; self.x = x; self.len = len; self.h = h; self.label = label
    }
    func covers(_ p: Float) -> Bool { p >= x && p < x + len }
}

struct Pop { let text: String; let color: NSColor; let big: Bool }

final class Game {
    var mode: Mode = .title
    var time: Float = 0
    var dist: Float = 0
    var speed: Float = 11
    var y: Float = 0
    var vy: Float = 0
    var trick: Trick?
    var trickT: Float = 0
    var combo: [String] = []
    var comboPts = 0
    var score = 0
    var bones = 0
    var bailT: Float = 0
    var obs: [Ob] = []
    var nextSpawn: Float = 45
    var seenTools = -1
    var wasWorking = false
    var pops: [Pop] = []
    var grindPts: Float = 0

    let baseSpeed: Float = 11
    let maxSpeed: Float = 23
    let gravity: Float = 64
    let ollie: Float = 22
    let kickerLaunch: Float = 29
    let bailTime: Float = 2.25

    func pop(_ text: String, _ color: NSColor, big: Bool = false) { pops.append(Pop(text: text, color: color, big: big)) }

    func at(_ kind: Kind, _ p: Float) -> Ob? { obs.first { $0.kind == kind && $0.covers(p) } }

    func spawn() {
        let r = Float.random(in: 0..<1)
        let x = nextSpawn
        var kind: Kind
        var len: Float = 1
        if r < 0.32 { kind = .rail; len = Float(Int.random(in: 8...18)) }
        else if r < 0.55 { kind = .kicker; len = 3 }
        else if r < 0.8 { kind = .cone }
        else { kind = .gap; len = Float(Int.random(in: 3...5)) }
        obs.append(Ob(kind: kind, x: x, len: len))
        nextSpawn = x + len + (kind == .kicker ? Float.random(in: 10...16) : Float.random(in: 16...38))
    }

    func addTrick(_ name: String, _ pts: Int) {
        let repeats = combo.filter { $0 == name }.count
        combo.append(name)
        comboPts += repeats > 0 ? pts / (repeats + 1) : pts
        pop(name, .white)
    }

    func bank() {
        guard !combo.isEmpty else { return }
        let total = comboPts * combo.count
        score += total
        pop("LANDED  +\(total.formatted())", NSColor(red: 0.36, green: 0.89, blue: 0.49, alpha: 1), big: true)
        combo = []; comboPts = 0
    }

    func bail(_ why: String) {
        let broken = Int.random(in: 1...3)
        let names = (0..<broken).map { _ in BONES.randomElement()! }
        bones += broken
        mode = .bail; bailT = bailTime
        trick = nil; trickT = 0; combo = []; comboPts = 0; vy = 0
        pop("BAILED: \(why). Broke \(names.joined(separator: ", "))", NSColor(red: 1, green: 0.56, blue: 0.64, alpha: 1), big: true)
    }

    func press(_ key: String) {
        if key == "r" {
            let keepBones = bones
            obs.forEach { $0.node?.removeFromParentNode() }
            obs = []; nextSpawn = dist + 45; score = 0; combo = []; comboPts = 0
            bones = keepBones; mode = .ride; y = 0; vy = 0; speed = baseSpeed; trick = nil
            pop("Fresh run", .white)
            return
        }
        if mode == .title {
            if key == "up" || key == "return" { mode = .ride; pop("Drop in!", NSColor(red: 0.36, green: 0.89, blue: 0.49, alpha: 1), big: true) }
            return
        }
        if (mode == .ride || mode == .grind) && key == "up" {
            mode = .air; vy = ollie
            if combo.isEmpty { comboPts = 0 }
            addTrick("Ollie", 25)
            return
        }
        if mode == .air, trick == nil, let t = TRICKS[key] { trick = t; trickT = t.duration }
    }

    func step(_ dt: Float, _ status: Status) {
        time += dt
        if status.working != wasWorking {
            wasWorking = status.working
            if !status.working && mode != .title { pop("CLAUDE FINISHED  ·  Esc to go back", NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1), big: true) }
        }
        if seenTools < 0 { seenTools = status.tools }
        if mode == .title { dist += dt * 3; seenTools = status.tools; return }

        // Each tool call Claude makes drops a token onto the course.
        let fresh = min(3, status.tools - seenTools)
        if fresh > 0 {
            for i in 0..<fresh {
                obs.append(Ob(kind: .token, x: dist + 70 + Float(i) * 5, len: 1, h: Float(Int.random(in: 2...4)), label: status.activity.isEmpty ? "tool" : status.activity))
            }
        }
        seenTools = status.tools

        if mode == .bail {
            bailT -= dt
            dist += speed * dt * max(0, bailT / bailTime)
            if bailT <= 0 {
                mode = .ride; speed = baseSpeed; y = 0
                for o in obs where o.kind != .token && o.x < dist + 12 && o.x + o.len > dist - 1 {
                    o.node?.removeFromParentNode(); o.node = nil
                }
                obs.removeAll { $0.kind != .token && $0.x < dist + 12 && $0.x + $0.len > dist - 1 }
            }
            return
        }

        speed = min(maxSpeed, speed + 0.2 * dt)
        let prevY = y
        dist += speed * dt
        while nextSpawn < dist + 170 { spawn() }
        for o in obs where o.x + o.len < dist - 30 { o.node?.removeFromParentNode(); o.node = nil }
        obs.removeAll { $0.x + $0.len < dist - 30 }

        let x = dist
        let gap = at(.gap, x), rail = at(.rail, x), kicker = at(.kicker, x), cone = at(.cone, x)

        for t in obs where t.kind == .token && !t.taken && abs(t.x - x) < 1.2 && abs(t.h - y) < 1.6 {
            t.taken = true
            score += 50
            pop("+50  \(t.label) token", NSColor(red: 0.85, green: 0.47, blue: 0.34, alpha: 1))
        }

        if mode == .ride {
            if gap != nil { mode = .air; vy = 0 }
            else if let k = kicker {
                y = (x - k.x + 1) / k.len * 0.9
                if x + speed * dt >= k.x + k.len { mode = .air; vy = kickerLaunch; pop("Kicker!", NSColor.orange) }
                return
            } else { y = 0 }
            if rail != nil && y < 0.8 { return bail("Ate the rail") }
            if cone != nil && y < 0.8 { return bail("Tripped on a cone") }
        }

        if mode == .grind {
            if rail == nil { mode = .air; vy = 6 }
            else {
                y = 1
                grindPts += 120 * dt
                let whole = Int(grindPts); grindPts -= Float(whole); comboPts += whole
                return
            }
        }

        if mode == .air {
            vy -= gravity * dt
            y += vy * dt
            if let t = trick {
                trickT -= dt
                if trickT <= 0 { addTrick(t.name, t.pts); trick = nil; trickT = 0 }
            }
            if rail != nil && prevY >= 1 && y <= 1 {
                if trick != nil { return bail("Sacked on the rail") }
                mode = .grind; y = 1; vy = 0
                addTrick("50-50 Grind", 100)
                return
            }
            if cone != nil && y < 0.8 && y >= 0 { return bail("Tripped on a cone") }
            if gap != nil && y < -1.5 { return bail("Fell into the gap") }
            if gap == nil && y <= 0 {
                if prevY < 0 { return bail("Slammed into the gap wall") }
                if let t = trick { return bail("Landed mid-\(t.name)") }
                y = 0; vy = 0; mode = .ride
                bank()
            }
        }
    }
}

// MARK: - Materials and textures

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255, blue: CGFloat(hex & 255) / 255, alpha: a)
}

func material(_ c: NSColor, rough: CGFloat = 0.7, metal: CGFloat = 0, emit: NSColor? = nil) -> SCNMaterial {
    let m = SCNMaterial()
    m.lightingModel = .physicallyBased
    m.diffuse.contents = c
    m.roughness.contents = rough
    m.metalness.contents = metal
    if let e = emit { m.emission.contents = e }
    return m
}

func image(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> NSImage {
    let img = NSImage(size: NSSize(width: w, height: h))
    img.lockFocus()
    if let ctx = NSGraphicsContext.current?.cgContext { draw(ctx) }
    img.unlockFocus()
    return img
}

func asphaltTexture() -> NSImage {
    image(256, 256) { ctx in
        ctx.setFillColor(color(0x2e2e36).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        for _ in 0..<1800 {
            let v = CGFloat.random(in: 0.12...0.26)
            ctx.setFillColor(NSColor(white: v, alpha: 1).cgColor)
            ctx.fill(CGRect(x: .random(in: 0..<256), y: .random(in: 0..<256), width: 2, height: 2))
        }
        // Two lane lines, dashed along the length (the texture's v axis).
        ctx.setFillColor(color(0xe8e0c0).cgColor)
        for lx in [CGFloat(76), CGFloat(176)] { ctx.fill(CGRect(x: lx, y: 0, width: 4, height: 128)) }
    }
}

func sidewalkTexture() -> NSImage {
    image(128, 128) { ctx in
        ctx.setFillColor(color(0x6b6870).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 128))
        ctx.setFillColor(color(0x4b4850).cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: 128, height: 3)); ctx.fill(CGRect(x: 0, y: 0, width: 3, height: 128))
    }
}

func curbTexture() -> NSImage {
    image(64, 64) { ctx in
        ctx.setFillColor(color(0xc0392b).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 32))
        ctx.setFillColor(color(0xece6da).cgColor); ctx.fill(CGRect(x: 0, y: 32, width: 64, height: 32))
    }
}

func windowsTexture(seed: Int) -> (NSImage, NSImage) {
    var rng = SystemRandomNumberGenerator()
    var lit: [CGRect] = []
    var dark: [CGRect] = []
    for row in 0..<16 { for col in 0..<8 {
        let r = CGRect(x: col * 32 + 6, y: row * 32 + 8, width: 20, height: 18)
        if Int.random(in: 0..<100, using: &rng) < 42 { lit.append(r) } else { dark.append(r) }
    } }
    let windowColor = [0xffd27a, 0xffb36b, 0xbfe3ff][seed % 3]
    let diffuse = image(256, 512) { ctx in
        ctx.setFillColor(NSColor.white.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
        ctx.setFillColor(NSColor(white: 0.25, alpha: 1).cgColor); dark.forEach { ctx.fill($0) }
    }
    let emission = image(256, 512) { ctx in
        ctx.setFillColor(NSColor.black.cgColor); ctx.fill(CGRect(x: 0, y: 0, width: 256, height: 512))
        ctx.setFillColor(color(UInt32(windowColor)).cgColor); lit.forEach { ctx.fill($0) }
    }
    return (diffuse, emission)
}

func skyImage() -> NSImage {
    // Stretched over a 16:9 view, so the sun is drawn 9/16 as wide to land round.
    image(512, 512) { ctx in
        let colors = [color(0xff9a5c).cgColor, color(0xe0507a).cgColor, color(0x4a2070).cgColor, color(0x0d0820).cgColor] as CFArray
        let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 0.12, 0.45, 1])!
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: 512 * 0.5), end: CGPoint(x: 0, y: 512), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        let r: CGFloat = 120
        let sun = CGRect(x: 256 - r * 9 / 16, y: 512 * 0.5, width: r * 2 * 9 / 16, height: r * 2)
        ctx.saveGState()
        ctx.addEllipse(in: sun)
        ctx.clip()
        let sunGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [color(0xff4f8b).cgColor, color(0xffd56b).cgColor] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sunGrad, start: CGPoint(x: 0, y: sun.minY), end: CGPoint(x: 0, y: sun.maxY), options: [])
        // Synthwave bands across the lower half.
        ctx.setBlendMode(.copy)
        var y = sun.minY + 6
        var gap: CGFloat = 9
        while y < sun.midY {
            ctx.setFillColor(color(0xe0507a).cgColor)
            ctx.fill(CGRect(x: sun.minX, y: y, width: sun.width, height: gap * 0.5))
            y += gap * 1.6
            gap = max(3, gap - 1.2)
        }
        ctx.restoreGState()
    }
}

// MARK: - Mesh helper (flat-shaded triangles)

func mesh(_ tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)], center: SIMD3<Float>) -> SCNGeometry {
    var verts: [SCNVector3] = []
    var norms: [SCNVector3] = []
    for (a, b, c) in tris {
        var n = simd_normalize(simd_cross(b - a, c - a))
        if simd_dot(n, (a + b + c) / 3 - center) < 0 { n = -n }
        for p in [a, b, c] { verts.append(SCNVector3(p)); norms.append(SCNVector3(n)) }
    }
    let idx = (0..<Int32(verts.count)).map { $0 }
    let el = SCNGeometryElement(indices: idx, primitiveType: .triangles)
    return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: norms)], elements: [el])
}

// MARK: - The world

final class World: NSObject, SCNSceneRendererDelegate {
    let scene = SCNScene()
    let game = Game()
    let feed: StatusFeed
    let cameraNode = SCNNode()
    let sun = SCNNode()
    let ground = SCNNode()
    var groundMaterials: [SCNMaterial] = []
    var buildings: [(node: SCNNode, side: Float, block: Int)] = []
    let skater = SCNNode()
    let board = SCNNode()
    let body = SCNNode()
    var limbs: [String: SCNNode] = [:]
    let sparks = SCNParticleSystem()
    let sparkNode = SCNNode()
    var lastTime: TimeInterval = 0
    var keyQueue: [String] = []
    let keyLock = NSLock()
    weak var hud: Hud?
    var lastReport: Float = 0
    var reported = (score: -1, bones: -1)

    let block: Float = 16

    init(feed: StatusFeed) {
        self.feed = feed
        super.init()
        build()
    }

    func enqueue(_ key: String) { keyLock.lock(); keyQueue.append(key); keyLock.unlock() }

    // MARK: Build

    func build() {
        scene.background.contents = skyImage()
        scene.fogStartDistance = 35
        scene.fogEndDistance = 210
        scene.fogDensityExponent = 1.4
        scene.fogColor = color(0x5a2a5a)

        let cam = SCNCamera()
        cam.fieldOfView = 62
        cam.zNear = 0.1
        cam.zFar = 400
        cam.wantsHDR = true
        cam.bloomIntensity = 1.1
        cam.bloomThreshold = 0.75
        cam.bloomBlurRadius = 10
        cam.motionBlurIntensity = 0.25
        cam.vignettingIntensity = 0.5
        cam.vignettingPower = 0.9
        cam.wantsExposureAdaptation = false
        cam.exposureOffset = 0.15
        cameraNode.camera = cam
        scene.rootNode.addChildNode(cameraNode)

        // Light: a low sunset sun with shadows, and a purple sky fill.
        let sunLight = SCNLight()
        sunLight.type = .directional
        sunLight.color = color(0xffb57a)
        sunLight.intensity = 1700
        sunLight.castsShadow = true
        sunLight.shadowMapSize = CGSize(width: 4096, height: 4096)
        sunLight.shadowMode = .forward
        sunLight.shadowSampleCount = 16
        sunLight.shadowRadius = 3
        sunLight.orthographicScale = 22
        sunLight.zNear = 1
        sunLight.zFar = 120
        sunLight.shadowColor = NSColor(white: 0, alpha: 0.65)
        sun.light = sunLight
        scene.rootNode.addChildNode(sun)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light!.type = .ambient
        ambient.light!.color = color(0x6a4a9a)
        ambient.light!.intensity = 550
        scene.rootNode.addChildNode(ambient)

        // Street, curbs, sidewalks: long strips that ride along, textures scrolled.
        func strip(width: CGFloat, x: Float, y: Float, texture: NSImage, repeatU: Float, repeatV: Float, rough: CGFloat) {
            let plane = SCNPlane(width: width, height: 400)
            let m = material(.white, rough: rough)
            m.diffuse.contents = texture
            m.diffuse.wrapS = .repeat; m.diffuse.wrapT = .repeat
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(CGFloat(repeatU), CGFloat(repeatV), 1)
            m.diffuse.mipFilter = .linear
            m.diffuse.maxAnisotropy = 16
            plane.firstMaterial = m
            let n = SCNNode(geometry: plane)
            n.eulerAngles.x = -.pi / 2
            n.position = SCNVector3(x, y, 0)
            ground.addChildNode(n)
            groundMaterials.append(m)
            m.setValue(NSNumber(value: repeatV), forKey: "repeatV")
            m.setValue(NSNumber(value: repeatU), forKey: "repeatU")
        }
        strip(width: 14, x: 0, y: 0, texture: asphaltTexture(), repeatU: 1, repeatV: 400 / 14, rough: 0.85)
        for side: Float in [-1, 1] {
            strip(width: 0.45, x: side * 7.2, y: 0.12, texture: curbTexture(), repeatU: 1, repeatV: 400 / 2.4, rough: 0.6)
            strip(width: 5, x: side * 9.9, y: 0.12, texture: sidewalkTexture(), repeatU: 3, repeatV: 400 / 1.8, rough: 0.9)
            let lot = SCNNode(geometry: SCNPlane(width: 60, height: 400))
            lot.geometry!.firstMaterial = material(color(0x1d1726))
            lot.eulerAngles.x = -.pi / 2
            lot.position = SCNVector3(side * 42, 0.05, 0)
            ground.addChildNode(lot)
        }
        scene.rootNode.addChildNode(ground)

        // Buildings both sides, recycled as the street scrolls.
        for i in 0..<16 { for side: Float in [-1, 1] {
            let n = SCNNode()
            scene.rootNode.addChildNode(n)
            buildings.append((n, side, -1))
            _ = i
        } }

        buildSkater()
        scene.rootNode.addChildNode(skater)

        sparks.birthRate = 0
        sparks.particleLifeSpan = 0.35
        sparks.particleSize = 0.025
        sparks.particleColor = color(0xffcc33)
        sparks.particleVelocity = 3
        sparks.particleVelocityVariation = 2
        sparks.spreadingAngle = 70
        sparks.emittingDirection = SCNVector3(0, 1, 1)
        sparks.acceleration = SCNVector3(0, -9.8, 0)
        sparks.blendMode = .additive
        sparks.isLightingEnabled = false
        sparkNode.addParticleSystem(sparks)
        scene.rootNode.addChildNode(sparkNode)
    }

    func buildSkater() {
        let deck = SCNBox(width: 0.21, height: 0.025, length: 0.8, chamferRadius: 0.012)
        let grip = material(color(0x1c1c20), rough: 0.95)
        let graphic = material(color(0xff4f8b), rough: 0.5, emit: color(0x401020))
        let wood = material(color(0xd9a066), rough: 0.6)
        deck.materials = [wood, wood, wood, wood, grip, graphic]
        board.addChildNode(SCNNode(geometry: deck))
        let wheel = SCNCylinder(radius: 0.028, height: 0.03)
        wheel.firstMaterial = material(color(0xf5f0e0), rough: 0.4)
        let truck = SCNBox(width: 0.16, height: 0.025, length: 0.04, chamferRadius: 0.005)
        truck.firstMaterial = material(color(0xb8c0cc), rough: 0.3, metal: 1)
        for z: Float in [-0.27, 0.27] {
            let t = SCNNode(geometry: truck); t.position = SCNVector3(0, -0.03, z); board.addChildNode(t)
            for x: Float in [-0.09, 0.09] {
                let w = SCNNode(geometry: wheel); w.eulerAngles.z = .pi / 2; w.position = SCNVector3(x, -0.05, z); board.addChildNode(w)
            }
        }
        skater.addChildNode(board)

        let shirt = material(color(0x3f8fff), rough: 0.8)
        let pants = material(color(0x2b3a55), rough: 0.9)
        let skin = material(color(0xe9b98a), rough: 0.6)
        let shoe = material(color(0xf2f2f2), rough: 0.7)
        func capsule(_ name: String, _ r: CGFloat, _ m: SCNMaterial) {
            let g = SCNCapsule(capRadius: r, height: 1)
            g.firstMaterial = m
            let n = SCNNode(geometry: g)
            limbs[name] = n
            body.addChildNode(n)
        }
        for side in ["L", "R"] {
            capsule("thigh" + side, 0.065, pants); capsule("shin" + side, 0.055, pants)
            capsule("arm" + side, 0.045, shirt); capsule("fore" + side, 0.04, skin)
            let s = SCNNode(geometry: SCNBox(width: 0.12, height: 0.07, length: 0.27, chamferRadius: 0.03))
            s.geometry!.firstMaterial = shoe
            limbs["shoe" + side] = s
            body.addChildNode(s)
        }
        capsule("torso", 0.16, shirt)
        let head = SCNNode(geometry: SCNSphere(radius: 0.12))
        head.geometry!.firstMaterial = skin
        let beanie = SCNNode(geometry: SCNSphere(radius: 0.125))
        beanie.geometry!.firstMaterial = material(color(0xd93a3a), rough: 0.9)
        beanie.scale = SCNVector3(1, 0.75, 1)
        beanie.position = SCNVector3(0, 0.05, 0)
        head.addChildNode(beanie)
        limbs["head"] = head
        body.addChildNode(head)
        skater.addChildNode(body)
        skater.enumerateHierarchy { n, _ in n.castsShadow = true }
    }

    // Places a capsule (unit height, along y) between two points.
    func place(_ name: String, _ a: SIMD3<Float>, _ b: SIMD3<Float>) {
        guard let n = limbs[name], let cap = n.geometry as? SCNCapsule else { return }
        let d = b - a
        let len = max(0.05, simd_length(d))
        cap.height = CGFloat(len) + cap.capRadius * 2
        n.simdPosition = (a + b) / 2
        n.simdOrientation = simd_quatf(from: SIMD3<Float>(0, 1, 0), to: simd_normalize(d))
    }

    // MARK: Per frame

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(0.05, time - lastTime))
        lastTime = time
        let status = feed.status

        keyLock.lock(); let keys = keyQueue; keyQueue = []; keyLock.unlock()
        keys.forEach { game.press($0) }
        game.step(dt, status)

        updateWorld(dt)
        updateSkater(dt)
        updateCamera(dt)
        hud?.update(game: game, status: status)

        lastReport += dt
        if lastReport > 1, (game.score, game.bones) != reported {
            lastReport = 0
            reported = (game.score, game.bones)
            print("RUN {\"score\":\(game.score),\"bones\":\(game.bones)}")
            fflush(stdout)
        }
    }

    func z(_ simX: Float) -> Float { -simX * S }

    func updateWorld(_ dt: Float) {
        let pz = z(game.dist)
        ground.position = SCNVector3(0, 0, pz - 150)
        // Scroll each strip's texture so the street moves under a fixed mesh.
        for m in groundMaterials {
            let rv = (m.value(forKey: "repeatV") as? NSNumber)?.floatValue ?? 1
            let ru = (m.value(forKey: "repeatU") as? NSNumber)?.floatValue ?? 1
            let offset = (pz - 150) / 400 * rv
            m.diffuse.contentsTransform = SCNMatrix4Mult(SCNMatrix4MakeScale(CGFloat(ru), CGFloat(rv), 1), SCNMatrix4MakeTranslation(0, CGFloat(-offset), 0))
        }
        sun.simdPosition = SIMD3<Float>(12, 30, pz - 35)
        sun.simdLook(at: SIMD3<Float>(0, 0, pz - 8))

        // Buildings: each slot takes the block it should show now.
        let firstBlock = Int(floor((game.dist - 25) / block))
        for i in buildings.indices {
            let want = firstBlock + i / 2
            if buildings[i].block != want {
                buildings[i].block = want
                fillBuilding(buildings[i].node, block: want, side: buildings[i].side)
            }
        }

        // Obstacles: make nodes for new ones, animate tokens.
        for o in game.obs {
            if o.node == nil { o.node = makeNode(o); if let n = o.node { scene.rootNode.addChildNode(n) } }
            if o.kind == .token, let n = o.node {
                n.isHidden = o.taken || o.x < game.dist - 1
                n.eulerAngles.y = CGFloat(game.time * 3 + o.x)
                n.position.y = CGFloat(o.h * S + 0.6 + sin(game.time * 4 + o.x) * 0.08)
            }
        }
    }

    func hash(_ n: Int) -> Float {
        let s = sin(Float(n) * 127.1 + 311.7) * 43758.5453
        return s - floor(s)
    }

    func fillBuilding(_ node: SCNNode, block b: Int, side: Float) {
        node.childNodes.forEach { $0.removeFromParentNode() }
        let r = hash(b * 2 + (side > 0 ? 1 : 0))
        if r < 0.1 { return } // an alley
        let len = (block - 2.5 - r * 2.5) * S
        let h = CGFloat(8 + hash(b * 7 + Int(side)) * 26)
        let depth: CGFloat = 12
        let box = SCNBox(width: depth, height: h, length: CGFloat(len), chamferRadius: 0)
        let palette: [UInt32] = [0x3b2f63, 0x2f4a6b, 0x5a2f4f, 0x2f5a54, 0x4a3a2a, 0x22324a]
        let base = color(palette[Int(r * 97) % palette.count])
        let (diffuse, emission) = windowsTexture(seed: b & 7)
        let face = material(base, rough: 0.8)
        face.multiply.contents = diffuse
        face.emission.contents = emission
        face.emission.intensity = 1.6
        let scaleU = CGFloat(len) / 6, scaleV = h / 12
        for p in [face.multiply, face.emission] { p.wrapS = .repeat; p.wrapT = .repeat; p.contentsTransform = SCNMatrix4MakeScale(scaleU, scaleV, 1) }
        let plain = material(base.blended(withFraction: 0.35, of: .black) ?? base, rough: 0.9)
        box.materials = [plain, side > 0 ? plain : face, plain, side > 0 ? face : plain, plain, plain]
        let n = SCNNode(geometry: box)
        let x = side * (12.4 + Float(depth) / 2)
        n.position = SCNVector3(x, Float(h) / 2, z(Float(b) * block + 1) - len / 2)
        node.addChildNode(n)

        // A neon strip along the roof edge that faces the street.
        let neonColors: [UInt32] = [0xff5fd2, 0x5ff2ff, 0xb8ff5f, 0xffb85f]
        let neon = SCNBox(width: 0.12, height: 0.12, length: CGFloat(len), chamferRadius: 0)
        let nc = color(neonColors[Int(r * 53) % neonColors.count])
        neon.firstMaterial = { let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = nc; m.emission.contents = nc; m.emission.intensity = 3; return m }()
        let strip = SCNNode(geometry: neon)
        strip.position = SCNVector3(side * 12.4, Float(h) - 0.2, Float(n.position.z))
        node.addChildNode(strip)
        let low = strip.clone(); low.position.y = CGFloat(3.2); node.addChildNode(low)

        // A street lamp every few blocks.
        if b % 3 == 0 {
            let pole = SCNNode(geometry: SCNCylinder(radius: 0.06, height: 5))
            pole.geometry!.firstMaterial = material(color(0x30303a), rough: 0.4, metal: 0.8)
            pole.position = SCNVector3(side * 8, 2.5, z(Float(b) * block + 2))
            let lamp = SCNNode(geometry: SCNSphere(radius: 0.22))
            lamp.geometry!.firstMaterial = { let m = SCNMaterial(); m.lightingModel = .constant; m.emission.contents = color(0xffe2a8); m.emission.intensity = 4; m.diffuse.contents = color(0xffe2a8); return m }()
            lamp.position = SCNVector3(0, 2.6, 0)
            pole.addChildNode(lamp)
            node.addChildNode(pole)
        }
        node.enumerateHierarchy { c, _ in c.castsShadow = false }
    }

    func makeNode(_ o: Ob) -> SCNNode? {
        let n = SCNNode()
        let z0 = z(o.x)
        switch o.kind {
        case .rail:
            let L = CGFloat(o.len * S)
            let bar = SCNNode(geometry: SCNCylinder(radius: 0.05, height: L))
            bar.geometry!.firstMaterial = material(color(0xdfe6f0), rough: 0.15, metal: 1)
            bar.eulerAngles.x = .pi / 2
            bar.position = SCNVector3(0, 1 * S - 0.035, z0 - Float(L) / 2)
            n.addChildNode(bar)
            var p: Float = 0
            while p <= o.len {
                let post = SCNNode(geometry: SCNCylinder(radius: 0.025, height: CGFloat(S)))
                post.geometry!.firstMaterial = material(color(0x70788a), rough: 0.3, metal: 1)
                post.position = SCNVector3(0, S / 2, z(o.x + p))
                n.addChildNode(post)
                p += 4
            }
        case .kicker:
            let w: Float = 0.9, h = 0.9 * S
            let a = z0, b = z(o.x + o.len)
            let L = SIMD3<Float>(-w, 0, a), R = SIMD3<Float>(w, 0, a)
            let Lb = SIMD3<Float>(-w, 0, b), Rb = SIMD3<Float>(w, 0, b)
            let Lt = SIMD3<Float>(-w, h, b), Rt = SIMD3<Float>(w, h, b)
            let center = SIMD3<Float>(0, h / 3, (a + b) / 2)
            let g = mesh([(L, R, Rt), (L, Rt, Lt), (L, Lb, Lt), (R, Rb, Rt), (Lb, Rb, Rt), (Lb, Rt, Lt)], center: center)
            g.firstMaterial = material(color(0xb07d4f), rough: 0.7)
            g.firstMaterial!.isDoubleSided = true
            n.addChildNode(SCNNode(geometry: g))
            let lip = SCNNode(geometry: SCNBox(width: CGFloat(w * 2), height: 0.02, length: 0.05, chamferRadius: 0))
            lip.geometry!.firstMaterial = material(color(0xd0d6e0), rough: 0.2, metal: 1)
            lip.position = SCNVector3(0, h, b)
            n.addChildNode(lip)
        case .cone:
            let cone = SCNNode(geometry: SCNCone(topRadius: 0.02, bottomRadius: 0.2, height: 0.55))
            cone.geometry!.firstMaterial = material(color(0xff6a00), rough: 0.5, emit: color(0x301000))
            cone.position = SCNVector3(0, 0.3, z0)
            let band = SCNNode(geometry: SCNCylinder(radius: 0.125, height: 0.07))
            band.geometry!.firstMaterial = material(.white, rough: 0.3)
            band.position = SCNVector3(0, 0.05, 0)
            cone.addChildNode(band)
            let base = SCNNode(geometry: SCNBox(width: 0.42, height: 0.04, length: 0.42, chamferRadius: 0.01))
            base.geometry!.firstMaterial = material(color(0xff6a00), rough: 0.5)
            base.position = SCNVector3(0, 0.02, z0)
            n.addChildNode(cone); n.addChildNode(base)
        case .gap:
            let L = CGFloat(o.len * S)
            let pit = SCNNode(geometry: SCNBox(width: 32, height: 0.02, length: L, chamferRadius: 0))
            pit.geometry!.firstMaterial = { let m = SCNMaterial(); m.lightingModel = .constant; m.diffuse.contents = NSColor.black; return m }()
            pit.position = SCNVector3(0, 0.13, z0 - Float(L) / 2)
            n.addChildNode(pit)
            for edge in [z0, z0 - Float(L)] {
                let stripe = SCNNode(geometry: SCNBox(width: 14, height: 0.03, length: 0.12, chamferRadius: 0))
                stripe.geometry!.firstMaterial = { let m = SCNMaterial(); m.lightingModel = .constant; m.emission.contents = color(0xffc400); m.diffuse.contents = color(0xffc400); return m }()
                stripe.position = SCNVector3(0, 0.14, edge)
                n.addChildNode(stripe)
            }
        case .token:
            let s: Float = 0.28
            let pts = [SIMD3<Float>(0, s * 1.4, 0), SIMD3<Float>(0, -s * 1.4, 0), SIMD3<Float>(s, 0, 0), SIMD3<Float>(-s, 0, 0), SIMD3<Float>(0, 0, s), SIMD3<Float>(0, 0, -s)]
            let ring = [2, 4, 3, 5]
            var tris: [(SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)] = []
            for i in 0..<4 {
                tris.append((pts[0], pts[ring[i]], pts[ring[(i + 1) % 4]]))
                tris.append((pts[1], pts[ring[i]], pts[ring[(i + 1) % 4]]))
            }
            let g = mesh(tris, center: .zero)
            let tints: [UInt32] = [0xd97757, 0x5be37d, 0x4fa3ff, 0xc792ea, 0xffcc33]
            let c = color(tints[o.label.count % tints.count])
            g.firstMaterial = material(c, rough: 0.2, metal: 0.3, emit: c)
            g.firstMaterial!.emission.intensity = 2.2
            let gem = SCNNode(geometry: g)
            n.addChildNode(gem)
            n.position = SCNVector3(0, o.h * S + 0.6, z0)
            return n
        }
        n.enumerateHierarchy { c, _ in c.castsShadow = true }
        return n
    }

    func updateSkater(_ dt: Float) {
        let pz = z(game.dist)
        let bailing = game.mode == .bail
        let baseY = bailing ? 0 : max(0, game.y) * S + 0.08 + (game.mode == .grind ? 0.03 : 0)
        skater.simdPosition = SIMD3<Float>(0, baseY, pz)

        // The board: roll for flips, spin for the tre, a pop up off the feet.
        var roll: Float = 0, spin: Float = 0, lift: Float = 0
        if let t = game.trick {
            let p = 1 - game.trickT / t.duration
            switch t.name {
            case "Kickflip": roll = p * 2 * .pi
            case "Heelflip": roll = -p * 2 * .pi
            case "Tre Flip": roll = p * 2 * .pi; spin = p * 2 * .pi
            default: break
            }
            lift = sin(p * .pi) * 0.35
        }
        if bailing {
            let k = game.bailTime - game.bailT
            board.simdPosition = SIMD3<Float>(0.3 * k, abs(sin(k * 6)) * 0.7 * max(0, 1 - k / 1.8), -k * 4)
            board.simdOrientation = simd_quatf(angle: k * 9, axis: simd_normalize(SIMD3<Float>(0.3, 0.6, 1)))
        } else {
            board.simdPosition = SIMD3<Float>(0, lift, 0)
            board.simdOrientation = simd_quatf(angle: spin, axis: SIMD3<Float>(0, 1, 0)) * simd_quatf(angle: roll, axis: SIMD3<Float>(0, 0, 1))
        }

        // The rider stands sideways on the board (facing +x), posed per state.
        let grab = game.trick?.name == "Indy Grab"
        let air = game.mode == .air
        let grind = game.mode == .grind
        let crouch: Float = grab ? 0.32 : air ? 0.16 : grind ? 0.08 : 0.04 + sin(game.time * 2) * 0.02
        let feetY: Float = 0.05 + lift
        let fL = SIMD3<Float>(0, feetY, 0.2), fR = SIMD3<Float>(0, feetY, -0.22)
        let hip = SIMD3<Float>(0, 0.92 - crouch, 0)
        let kL = SIMD3<Float>(0.12, 0.5 - crouch * 0.5 + lift * 0.5, 0.13), kR = SIMD3<Float>(0.12, 0.5 - crouch * 0.5 + lift * 0.5, -0.15)
        let chest = SIMD3<Float>(0.03, 1.38 - crouch * 1.1, 0)
        let shL = SIMD3<Float>(0, 1.36 - crouch, 0.17), shR = SIMD3<Float>(0, 1.36 - crouch, -0.17)
        let swing = sin(game.time * 3) * 0.1
        var hL = SIMD3<Float>(0.05, 1.0 - crouch + swing, 0.55), hR = SIMD3<Float>(0.05, 1.05 - crouch - swing, -0.55)
        if grind { hL = SIMD3<Float>(0, 1.3, 0.8); hR = SIMD3<Float>(0, 1.25, -0.8) }
        if grab { hR = SIMD3<Float>(0.12, 0.12 + lift, 0) }
        let elbow = { (s: SIMD3<Float>, h: SIMD3<Float>) in (s + h) / 2 + SIMD3<Float>(0.06, -0.06, 0) }
        place("shinL", fL, kL); place("thighL", kL, hip)
        place("shinR", fR, kR); place("thighR", kR, hip)
        place("torso", hip + SIMD3<Float>(0, 0.12, 0), chest)
        place("armL", shL, elbow(shL, hL)); place("foreL", elbow(shL, hL), hL)
        place("armR", shR, elbow(shR, hR)); place("foreR", elbow(shR, hR), hR)
        limbs["shoeL"]?.simdPosition = fL + SIMD3<Float>(0, 0.02, 0)
        limbs["shoeR"]?.simdPosition = fR + SIMD3<Float>(0, 0.02, 0)
        limbs["shoeL"]?.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        limbs["shoeR"]?.simdOrientation = simd_quatf(angle: .pi / 2, axis: SIMD3<Float>(0, 1, 0))
        limbs["head"]?.simdPosition = SIMD3<Float>(0.03, 1.62 - crouch * 1.1, 0)

        if bailing {
            let k = min(1, (game.bailTime - game.bailT) / 0.5)
            body.simdOrientation = simd_quatf(angle: k * .pi / 2 * 0.95, axis: SIMD3<Float>(0, 0, 1)) * simd_quatf(angle: k * 0.6, axis: SIMD3<Float>(1, 0, 0))
            body.simdPosition = SIMD3<Float>(-k * 0.2, 0.12 * k, 0)
        } else {
            body.simdOrientation = simd_quatf(angle: 0.35, axis: SIMD3<Float>(0, 1, 0)) // open a little toward the camera
            body.simdPosition = .zero
        }

        sparks.birthRate = grind ? 450 : 0
        sparkNode.simdPosition = SIMD3<Float>(0, baseY, pz + 0.3)
    }

    var camPos = SIMD3<Float>(0, 3, 6)
    var camLook = SIMD3<Float>(0, 1, 0)

    func updateCamera(_ dt: Float) {
        let pz = z(game.dist)
        let yy = max(0, game.y) * S
        let speedPull = (game.speed - game.baseSpeed) / (game.maxSpeed - game.baseSpeed)
        var target = SIMD3<Float>(0.6, 2.4 + yy * 0.45, pz + 5.2 + speedPull * 1.2)
        var look = SIMD3<Float>(0, 0.9 + yy * 0.6, pz - 6)
        if game.mode == .title {
            let t = game.time * 0.25
            target = SIMD3<Float>(sin(t) * 4, 2.2 + sin(t * 0.7), pz + 4 + cos(t) * 2)
            look = SIMD3<Float>(0, 1, pz - 4)
        }
        if game.mode == .bail && game.bailT > game.bailTime - 0.4 {
            target += SIMD3<Float>(Float.random(in: -0.12...0.12), Float.random(in: -0.12...0.12), 0)
        }
        let k = 1 - exp(-dt * 7)
        camPos += (target - camPos) * k
        camLook += (look - camLook) * k
        cameraNode.simdPosition = camPos
        cameraNode.simdLook(at: camLook)
        cameraNode.camera?.fieldOfView = CGFloat(62 + speedPull * 10)
    }
}

// MARK: - HUD (SpriteKit overlay)

final class Hud: SKScene {
    let score = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    let best = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    let meat = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    let claude = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    let combo = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    let title = SKLabelNode(fontNamed: "AvenirNext-Heavy")
    let subtitle = SKLabelNode(fontNamed: "AvenirNext-DemiBold")
    let help = SKLabelNode(fontNamed: "AvenirNext-Medium")
    var shownPops = 0
    var lastSize = CGSize.zero

    override init(size: CGSize) {
        super.init(size: size)
        scaleMode = .resizeFill
        backgroundColor = .clear
        for l in [score, best, meat, claude, combo, title, subtitle, help] { addChild(l) }
        for l in [score, best, meat] { l.horizontalAlignmentMode = .left }
        claude.horizontalAlignmentMode = .right
        score.fontSize = 34
        best.fontSize = 16; meat.fontSize = 16; claude.fontSize = 17
        combo.fontSize = 26; combo.fontColor = color(0xffcc33)
        title.fontSize = 64; title.text = "SKATE WHILE YOU WAIT"; title.fontColor = color(0xffe2a8)
        subtitle.fontSize = 22; subtitle.text = "Press SPACE to drop in"
        help.fontSize = 14; help.fontColor = NSColor(white: 1, alpha: 0.65)
        help.text = "SPACE ollie   ← kickflip   → heelflip   ↓ grab   ↑ (air) tre flip   R new run   Esc back to Claude"
        meat.fontColor = color(0xff8fa3)
        best.fontColor = NSColor(white: 1, alpha: 0.75)
    }

    required init?(coder: NSCoder) { fatalError() }

    func layout() {
        guard size != lastSize else { return }
        lastSize = size
        score.position = CGPoint(x: 28, y: size.height - 52)
        best.position = CGPoint(x: 30, y: size.height - 78)
        meat.position = CGPoint(x: 30, y: size.height - 100)
        claude.position = CGPoint(x: size.width - 28, y: size.height - 46)
        combo.position = CGPoint(x: size.width / 2, y: 70)
        title.position = CGPoint(x: size.width / 2, y: size.height * 0.62)
        subtitle.position = CGPoint(x: size.width / 2, y: size.height * 0.62 - 50)
        help.position = CGPoint(x: size.width / 2, y: 22)
    }

    func update(game: Game, status: Status) {
        layout()
        score.text = game.score.formatted()
        best.text = "BEST \(max(status.best, game.score).formatted())"
        meat.text = "INJURY REPORT  \((status.bones + game.bones).formatted()) bones"
        let spin = ["◐", "◓", "◑", "◒"][Int(game.time * 6) % 4]
        claude.text = status.working ? "\(spin)  Claude: \(status.activity.isEmpty ? "thinking" : status.activity)  ·  \(status.tools) tools" : "●  Claude is idle"
        claude.fontColor = status.working ? color(0xd97757) : color(0x5be37d)
        combo.text = game.combo.isEmpty ? "" : "\(game.combo.joined(separator: " + "))   ×\(game.combo.count)   \(game.comboPts.formatted())"
        let onTitle = game.mode == .title
        title.isHidden = !onTitle; subtitle.isHidden = !onTitle
        subtitle.alpha = 0.6 + 0.4 * CGFloat(abs(sin(game.time * 3)))

        while shownPops < game.pops.count {
            show(game.pops[shownPops]); shownPops += 1
        }
    }

    func show(_ p: Pop) {
        let l = SKLabelNode(fontNamed: "AvenirNext-Heavy")
        l.text = p.text
        l.fontColor = p.color
        l.fontSize = p.big ? 30 : 22
        l.position = CGPoint(x: size.width / 2, y: size.height * (p.big ? 0.72 : 0.58) + CGFloat.random(in: -10...10))
        l.setScale(0.6)
        addChild(l)
        l.run(.sequence([
            .group([.scale(to: 1, duration: 0.12), .fadeIn(withDuration: 0.1)]),
            .wait(forDuration: p.big ? 1.6 : 0.5),
            .group([.moveBy(x: 0, y: 40, duration: 0.5), .fadeOut(withDuration: 0.5)]),
            .removeFromParent(),
        ]))
    }
}

// MARK: - Window and input

final class GameView: SCNView {
    var onKey: ((String) -> Void)?
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.isARepeat { return }
        switch event.keyCode {
        case 49, 13, 126: onKey?("up")
        case 123, 0: onKey?("left")
        case 124, 2: onKey?("right")
        case 125, 1: onKey?("down")
        case 36: onKey?("return")
        case 15: onKey?("r")
        case 53: NSApp.hide(nil)
        default: super.keyDown(with: event)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow!
    var world: World!
    let feed: StatusFeed
    let activate: Bool

    init(statusPath: String, activate: Bool) {
        feed = StatusFeed(path: statusPath)
        self.activate = activate
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        menu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "Hide Skate", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Skate", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        NSApp.mainMenu = menu

        world = World(feed: feed)
        let view = GameView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.scene = world.scene
        view.delegate = world
        view.isPlaying = true
        view.rendersContinuously = true
        view.preferredFramesPerSecond = 120
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .black
        let hud = Hud(size: view.bounds.size)
        view.overlaySKScene = hud
        world.hud = hud
        view.onKey = { [weak self] k in self?.world.enqueue(k) }

        window = NSWindow(contentRect: view.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Skate While You Wait"
        window.contentView = view
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.setFrameAutosaveName("SkateClaudeWindow")
        if !window.setFrameUsingName("SkateClaudeWindow") { window.center() }
        window.makeFirstResponder(view)
        window.isReleasedWhenClosed = false

        feed.onRaise = { [weak self] in self?.raise() }
        feed.start()
        if activate { raise() } else { window.orderFrontRegardless() }
        if let i = CommandLine.arguments.firstIndex(of: "--snapshot"), i + 1 < CommandLine.arguments.count {
            snapshots(view: view, dir: CommandLine.arguments[i + 1])
        }
    }

    // Development aid: a bot plays and frames are saved as PNGs, then it quits.
    func snapshots(view: SCNView, dir: String) {
        world.enqueue("up")
        Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            guard let g = self?.world.game else { return }
            if g.mode == .ride, let o = g.obs.first(where: { $0.kind != .token && $0.kind != .kicker && $0.x > g.dist && $0.x - g.dist < 5 }) { _ = o; self?.world.enqueue("up") }
            if g.mode == .air, g.vy > 8, g.trick == nil, Int.random(in: 0..<3) == 0 { self?.world.enqueue(["left", "right", "up", "down"].randomElement()!) }
        }
        for (i, t) in [2.5, 4.0, 5.5, 7.0, 8.5, 10.0].enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                let img = view.snapshot()
                if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: "\(dir)/frame-\(i).png"))
                }
                if i == 5 { NSApp.terminate(nil) }
            }
        }
    }

    func raise() {
        NSApp.unhide(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ app: NSApplication) -> Bool { true }
}

// MARK: - Main

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
let statusPath = args.count > 1 ? args[1] : NSTemporaryDirectory() + "skate-status.json"
let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate(statusPath: statusPath, activate: args.contains("--activate"))
app.delegate = delegate
app.run()
