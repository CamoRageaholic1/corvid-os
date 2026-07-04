/* =============================================================================
 * Corvid OS — Calamares install-time slideshow
 * =============================================================================
 * A minimal, dark, three-slide presentation shown while packages install.
 * Uses the Calamares slideshow API v2 (Presentation from calamares.slideshow).
 * ============================================================================= */
import QtQuick 2.0
import calamares.slideshow 1.0

Presentation {
    id: presentation

    // advance slides on a timer while the install runs
    Timer {
        id: advanceTimer
        interval: 8000
        running: presentation.activatedInCalamares
        repeat: true
        onTriggered: presentation.goToNextSlide()
    }

    function onActivate() { presentation.currentSlide = 0; }
    function onLeave() { }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0C12"
            Column {
                anchors.centerIn: parent
                spacing: 18
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "CORVID OS"
                    color: "#E8ECF4"
                    font.pixelSize: 52
                    font.letterSpacing: 6
                    font.bold: true
                }
                Text {
                    anchors.horizontalCenter: parent.horizontalCenter
                    text: "Secure. Coding-friendly. Dark by design."
                    color: "#27E0C8"
                    font.pixelSize: 20
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0C12"
            Column {
                anchors.centerIn: parent
                spacing: 14
                width: parent.width * 0.7
                Text {
                    text: "Encrypted by default"
                    color: "#E8ECF4"
                    font.pixelSize: 34
                    font.bold: true
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Your install uses LUKS full-disk encryption out of the box. "
                        + "A single passphrase protects the whole system at rest."
                    color: "#6B768C"
                    font.pixelSize: 18
                }
            }
        }
    }

    Slide {
        Rectangle {
            anchors.fill: parent
            color: "#0A0C12"
            Column {
                anchors.centerIn: parent
                spacing: 14
                width: parent.width * 0.7
                Text {
                    text: "Batteries included"
                    color: "#E8ECF4"
                    font.pixelSize: 34
                    font.bold: true
                }
                Text {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: "Full pentest toolset, a complete dev stack, containers, "
                        + "and CZD-Tools — ready the moment you first log in."
                    color: "#6B768C"
                    font.pixelSize: 18
                }
            }
        }
    }
}
