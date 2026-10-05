"""Menu bar (system tray) toggle for a VPN.

The VPN itself is driven by a control command with three subcommands:

    <command> up       log in and connect; exits once connected (non-zero on failure)
    <command> down     disconnect
    <command> status   print a one-line description; exit 0 if connected, 3 if the tunnel
                       is down but the client is still trying to reconnect, else 1
"""

import argparse
import os
import shlex
import subprocess
import sys

from PyQt6.QtCore import QProcess, QRectF, Qt, QTimer
from PyQt6.QtGui import QColor, QIcon, QPainter, QPainterPath, QPen, QPixmap
from PyQt6.QtWidgets import QApplication, QMenu, QSystemTrayIcon

POLL_INTERVAL_MS = 5000


def lock_icon(closed, filled):
    """Menu bar lock drawn as a template (mask) image, so macOS tints it for light/dark."""
    size = 44  # 22pt @2x
    pixmap = QPixmap(size, size)
    pixmap.setDevicePixelRatio(2)
    pixmap.fill(Qt.GlobalColor.transparent)

    painter = QPainter(pixmap)
    painter.setRenderHint(QPainter.RenderHint.Antialiasing)
    painter.setPen(QPen(QColor("black"), 2))

    # Shackle: an arch whose right leg drops into the body when closed.
    lift = 0 if closed else 3
    shackle = QPainterPath()
    shackle.moveTo(7, 10)
    shackle.lineTo(7, 7 - lift)
    shackle.arcTo(QRectF(7, 3 - lift, 8, 8), 180, -180)
    shackle.lineTo(15, (10 if closed else 6) - lift)
    painter.drawPath(shackle)

    painter.setBrush(QColor("black") if filled else Qt.BrushStyle.NoBrush)
    painter.drawRoundedRect(QRectF(4.5, 10, 13, 9.5), 2, 2)
    painter.end()

    icon = QIcon(pixmap)
    icon.setIsMask(True)
    return icon


def hide_dock_icon():
    """Run as a menu bar-only (accessory) app: no Dock icon, no app menu."""
    if sys.platform != "darwin":
        return
    import ctypes
    import ctypes.util

    objc = ctypes.cdll.LoadLibrary(ctypes.util.find_library("objc"))
    objc.objc_getClass.restype = ctypes.c_void_p
    objc.sel_registerName.restype = ctypes.c_void_p
    send = ctypes.CFUNCTYPE(ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p)
    send_long = ctypes.CFUNCTYPE(
        ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_long
    )
    msg = ctypes.cast(objc.objc_msgSend, ctypes.c_void_p).value

    ns_app = send(msg)(
        objc.objc_getClass(b"NSApplication"),
        objc.sel_registerName(b"sharedApplication"),
    )
    accessory = 1  # NSApplicationActivationPolicyAccessory
    send_long(msg)(ns_app, objc.sel_registerName(b"setActivationPolicy:"), accessory)


class Menubar:
    def __init__(self, command, name, log_file):
        self.command = command
        self.name = name
        self.connected = False
        self.reconnecting = False
        self.detail = ""
        self.action_process = None  # running `up` / `down`
        self.status_process = None
        self.last_error = ""

        self.icons = {
            "disconnected": lock_icon(closed=False, filled=False),
            "busy": lock_icon(closed=True, filled=False),
            "connected": lock_icon(closed=True, filled=True),
        }

        self.menu = QMenu()
        self.status_action = self.menu.addAction("")
        self.status_action.setEnabled(False)
        self.menu.addSeparator()
        self.toggle_action = self.menu.addAction("")
        self.toggle_action.triggered.connect(self.toggle)
        if log_file:
            self.menu.addAction("Show Log").triggered.connect(
                lambda: self.show_log(log_file)
            )
        self.menu.addSeparator()
        self.menu.addAction("Quit").triggered.connect(QApplication.quit)

        self.tray = QSystemTrayIcon()
        self.tray.setContextMenu(self.menu)
        self.render()
        self.tray.show()

        self.timer = QTimer()
        self.timer.timeout.connect(self.refresh)
        self.timer.start(POLL_INTERVAL_MS)
        self.refresh()

    def show_log(self, log_file):
        if os.path.exists(log_file):
            subprocess.Popen(["/usr/bin/open", "-a", "Console", log_file])
        else:
            self.tray.showMessage(self.name, "No log yet: it's created on the first connect.")

    # State

    def busy(self):
        return self.action_process is not None

    def render(self):
        if self.busy():
            state, text = "busy", self.action_process.property("label")
        elif self.reconnecting:
            state, text = "busy", self.detail or "Reconnecting…"
        elif self.connected:
            state, text = "connected", self.detail or "Connected"
        else:
            state, text = "disconnected", self.last_error or "Disconnected"

        self.tray.setIcon(self.icons[state])
        self.tray.setToolTip(f"{self.name}: {text}")
        self.status_action.setText(f"{self.name}: {text}")
        self.toggle_action.setText(
            "Disconnect" if self.connected or self.reconnecting else "Connect"
        )
        self.toggle_action.setEnabled(not self.busy())

    # Commands

    def run(self, subcommand):
        process = QProcess()
        process.setProcessChannelMode(QProcess.ProcessChannelMode.MergedChannels)
        process.start(self.command[0], self.command[1:] + [subcommand])
        return process

    def refresh(self):
        if self.status_process is not None or self.busy():
            return
        process = self.status_process = self.run("status")

        def done(exit_code, _status):
            self.status_process = None
            was_up = self.connected or self.reconnecting
            self.connected = exit_code == 0
            self.reconnecting = exit_code == 3
            output = bytes(process.readAll()).decode(errors="replace").strip()
            last_line = output.splitlines()[-1] if output else ""
            self.detail = last_line if self.connected or self.reconnecting else ""
            if was_up and not (self.connected or self.reconnecting):
                # Dropped without the user clicking Disconnect (that path is "busy").
                self.last_error = last_line or "Connection lost"
                self.tray.showMessage(
                    self.name,
                    f"Connection lost: {self.last_error}",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
            self.render()

        process.finished.connect(done)

    def toggle(self):
        if self.busy():
            return
        subcommand = "down" if self.connected or self.reconnecting else "up"
        process = self.action_process = self.run(subcommand)
        process.setProperty(
            "label", "Disconnecting…" if subcommand == "down" else "Connecting…"
        )
        self.last_error = ""
        self.render()

        def done(exit_code, _status):
            self.action_process = None
            if subcommand == "down" and exit_code == 0:
                # Intentional disconnect: don't report it as a lost connection.
                self.connected = self.reconnecting = False
            if exit_code != 0:
                output = bytes(process.readAll()).decode(errors="replace").strip()
                reason = output.splitlines()[-1] if output else f"exit code {exit_code}"
                self.last_error = f"{subcommand} failed"
                self.tray.showMessage(
                    self.name,
                    f"{'Disconnect' if subcommand == 'down' else 'Connect'} failed: {reason}",
                    QSystemTrayIcon.MessageIcon.Warning,
                )
            self.render()
            self.refresh()

        process.finished.connect(done)


def main():
    parser = argparse.ArgumentParser(
        prog="openconnect-sso-menubar",
        description="Menu bar toggle for a VPN control command with up/down/status subcommands",
    )
    parser.add_argument(
        "--command", required=True, help="VPN control command, e.g. 'work-vpn'"
    )
    parser.add_argument("--name", default="VPN", help="Name shown in the menu")
    parser.add_argument("--log", help="Log file opened by 'Show Log'")
    args = parser.parse_args()

    app = QApplication(sys.argv[:1])
    app.setQuitOnLastWindowClosed(False)
    hide_dock_icon()

    if not QSystemTrayIcon.isSystemTrayAvailable():
        print("No system tray / menu bar available", file=sys.stderr)
        return 1

    menubar = Menubar(shlex.split(args.command), args.name, args.log)  # noqa: F841
    return app.exec()


if __name__ == "__main__":
    sys.exit(main())
