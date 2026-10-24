pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.services

Item {
    id: root

    required property ScreenState screenState

    readonly property bool shouldBeActive:
        Boolean(screenState && screenState.hotspotQr)

    // Drives Regions.qml's click-through mask - without this the mask keeps
    // blocking clicks over this panel's footprint even while it's closed.
    property real offsetScale: shouldBeActive ? 0 : 1

    Behavior on offsetScale {
        Anim {}
    }

	width: Math.min(420, parent.width * 0.8)
	height: Math.min(520, parent.height * 0.8)

    implicitWidth: 420
    implicitHeight: 520

    visible: false
    enabled: false

    opacity: 0
    scale: 0.95

    property real slideX: 0
    property real slideY: -40

    transform: Translate {
        x: root.slideX
        y: root.slideY
    }

    states: [
        State {
            name: "active"
            when: root.shouldBeActive

            PropertyChanges {
                target: root

                visible: true
                enabled: true

                opacity: 1
                scale: 1.0

                slideX: 0
                slideY: 0
            }
        },

        State {
            name: "inactive"
            when: !root.shouldBeActive

            PropertyChanges {
                target: root

                visible: false
                enabled: false

                opacity: 0
                scale: 0.95

                slideX: 0
                slideY: -40
            }
        }
    ]

    transitions: [
        Transition {
            from: "inactive"
            to: "active"

            NumberAnimation {
                properties: "opacity,scale,slideX,slideY"
                duration: 280
                easing.type: Easing.OutCubic
            }
        },

        Transition {
            from: "active"
            to: "inactive"

            NumberAnimation {
                properties: "opacity,scale,slideX,slideY"
                duration: 200
                easing.type: Easing.InCubic
            }
        }
    ]

    Shortcut {
		sequence: "Escape"
		enabled: root.shouldBeActive

		onActivated: {
		    if (root.shouldBeActive)
		        root.screenState.hotspotQr = false
		}
	}

    Loader {
        id: contentLoader

        anchors.fill: parent

        active: root.visible

        sourceComponent: Content {
            screenState: root.screenState
        }
    }
}
