pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.components
import qs.services

Item {
    id: root

    required property ScreenState screenState

    readonly property bool shouldBeActive:
        Boolean(screenState && screenState.cheatsheet)

    // Drives Regions.qml's click-through mask, same convention every other
    // panel wrapper uses - without this, this panel's area is never carved
    // out of the click-passthrough canvas, so every click on it (pills,
    // search, anything) falls straight through to whatever's underneath,
    // which reads as an "outside click" and closes the whole thing
    property real offsetScale: shouldBeActive ? 0 : 1

    Behavior on offsetScale {
        Anim {}
    }

	width: Math.min(1200, parent.width * 0.8)
	height: Math.min(900, parent.height * 0.8)

    implicitWidth: 1200
    implicitHeight: 900

    visible: false
    enabled: false

    opacity: 0
    scale: 0.95

    property real slideX: 0
    property real slideY: -250

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
                slideY: -250
            }
        }
    ]

    transitions: [
        Transition {
            from: "inactive"
            to: "active"

            NumberAnimation {
                properties: "opacity,scale,slideX,slideY"
                duration: 320
                easing.type: Easing.OutCubic
            }
        },

        Transition {
            from: "active"
            to: "inactive"

            NumberAnimation {
                properties: "opacity,scale,slideX,slideY"
                duration: 220
                easing.type: Easing.InCubic
            }
        }
    ]

    Loader {
        id: contentLoader
    
        anchors.fill: parent
        active: root.visible

        sourceComponent: Content {
            screenState: root.screenState
        }
    }
}
