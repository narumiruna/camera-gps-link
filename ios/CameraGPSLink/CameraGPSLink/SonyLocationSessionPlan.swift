import Foundation

enum SonyLocationActionKind: Equatable {
    case notify(Bool)
    case write(Data)
    case read
}

struct SonyLocationAction: Equatable {
    let name: String
    let uuid: String
    let kind: SonyLocationActionKind
    let required: Bool
}

struct SonyLocationSessionPlan: Equatable {
    let profile: SonyLocationProfileKind
    let setup: [SonyLocationAction]

    static func make(profile: SonyLocationProfile) -> SonyLocationSessionPlan {
        guard profile.isExecutable else {
            return SonyLocationSessionPlan(profile: .unsupported, setup: [])
        }
        guard profile.kind == .modern else {
            return SonyLocationSessionPlan(
                profile: .legacy,
                setup: [
                    SonyLocationAction(
                        name: "DD21 config",
                        uuid: SonyProtocol.locationConfigReadUUID,
                        kind: .read,
                        required: true
                    ),
                ]
            )
        }

        var setup: [SonyLocationAction] = []
        if profile.hasStatusNotifications {
            setup.append(
                SonyLocationAction(
                    name: "DD01 notify",
                    uuid: SonyProtocol.locationStatusNotifyUUID,
                    kind: .notify(true),
                    required: false
                )
            )
        }
        setup.append(
            SonyLocationAction(
                name: "DD30 lock",
                uuid: SonyProtocol.locationLockUUID,
                kind: .write(Data([0x01])),
                required: true
            )
        )
        setup.append(
            SonyLocationAction(
                name: "DD31 enable",
                uuid: SonyProtocol.locationEnableUUID,
                kind: .write(Data([0x01])),
                required: true
            )
        )
        if profile.hasTimeCorrection {
            setup.append(
                SonyLocationAction(
                    name: "DD32 time correction",
                    uuid: SonyProtocol.timeCorrectionUUID,
                    kind: .read,
                    required: false
                )
            )
        }
        if profile.hasAreaAdjustment {
            setup.append(
                SonyLocationAction(
                    name: "DD33 area adjustment",
                    uuid: SonyProtocol.areaAdjustmentUUID,
                    kind: .read,
                    required: false
                )
            )
        }
        setup.append(
            SonyLocationAction(
                name: "DD21 config",
                uuid: SonyProtocol.locationConfigReadUUID,
                kind: .read,
                required: true
            )
        )
        return SonyLocationSessionPlan(profile: .modern, setup: setup)
    }
}

struct SonyLocationAcquisition: Equatable {
    var dd30 = false
    var dd31 = false
    var dd01 = false

    mutating func recordAttempt(actionName: String) {
        recordSuccess(actionName: actionName)
    }

    mutating func recordSuccess(actionName: String) {
        switch actionName {
        case "DD30 lock":
            dd30 = true
        case "DD31 enable":
            dd31 = true
        case "DD01 notify":
            dd01 = true
        default:
            break
        }
    }

    var compensation: [SonyLocationAction] {
        var actions: [SonyLocationAction] = []
        if dd31 {
            actions.append(
                SonyLocationAction(
                    name: "DD31 disable",
                    uuid: SonyProtocol.locationEnableUUID,
                    kind: .write(Data([0x00])),
                    required: false
                )
            )
        }
        if dd30 {
            actions.append(
                SonyLocationAction(
                    name: "DD30 unlock",
                    uuid: SonyProtocol.locationLockUUID,
                    kind: .write(Data([0x00])),
                    required: false
                )
            )
        }
        if dd01 {
            actions.append(
                SonyLocationAction(
                    name: "DD01 notify stop",
                    uuid: SonyProtocol.locationStatusNotifyUUID,
                    kind: .notify(false),
                    required: false
                )
            )
        }
        return actions
    }
}

protocol SonyLocationSessionPlanning {
    func makePlan(profile: SonyLocationProfile) -> SonyLocationSessionPlan
}

struct DefaultSonyLocationSessionPlanner: SonyLocationSessionPlanning {
    func makePlan(profile: SonyLocationProfile) -> SonyLocationSessionPlan {
        SonyLocationSessionPlan.make(profile: profile)
    }
}

protocol SonyLocationSessionExecuting {
    func execute(plan: SonyLocationSessionPlan, enqueue: (SonyLocationAction) -> Void)
}

struct DefaultSonyLocationSessionExecutor: SonyLocationSessionExecuting {
    func execute(plan: SonyLocationSessionPlan, enqueue: (SonyLocationAction) -> Void) {
        plan.setup.forEach(enqueue)
    }
}
