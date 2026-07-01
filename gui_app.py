import os
import sys
import json
import uuid
import datetime
import traceback
import zipfile
import xml.etree.ElementTree as ET
import io
import string
from pathlib import Path

from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QLabel, QTextEdit, QComboBox,
    QPushButton, QLineEdit, QMessageBox, QFileDialog, QInputDialog,
    QFrame, QDialog, QVBoxLayout, QDialogButtonBox, QFormLayout
)
from PyQt6.QtCore import Qt, QTimer, QPoint, QSize, QProcess, QProcessEnvironment
from PyQt6.QtGui import QFont, QColor, QPalette, QIcon

PROJECT_ROOT = Path(__file__).parent.resolve()
COMMANDS_DIR = PROJECT_ROOT / ".zerotracefs" / "commands"
PROCESSED_DIR = PROJECT_ROOT / ".zerotracefs" / "processed"
MOUNT_DIR = PROJECT_ROOT / "mount"
STATUS_FILE = PROJECT_ROOT / ".zerotracefs" / "status.json"
CONTAINER_FILE = PROJECT_ROOT / "data" / "container.pkl"

COMMANDS_DIR.mkdir(parents=True, exist_ok=True)
PROCESSED_DIR.mkdir(parents=True, exist_ok=True)

# Try to load PyMuPDF for native PDF rendering
try:
    import fitz
    HAS_PYMUPDF = True
except ImportError:
    HAS_PYMUPDF = False

from zerotracefs.encryption import EncryptionEngine
from zerotracefs.key_derivation import KeyDerivation

from PyQt6.QtWidgets import QHBoxLayout, QSlider

class UniversalViewerDialog(QDialog):
    def __init__(self, parent, filename, content_bytes):
        super().__init__(parent)
        self.filename = filename
        self.content_bytes = content_bytes
        self.zoom_level = 100
        
        self.setWindowTitle(f"ZeroTraceFS Secure Viewer - {filename}")
        self.resize(1024, 768)
        self.setWindowFlags(self.windowFlags() | Qt.WindowType.WindowMaximizeButtonHint)
        self.setStyleSheet("background-color: #0f172a; color: #e2e8f0;")
        
        self.main_layout = QVBoxLayout(self)
        
        # Viewer container
        self.viewer_container = QWidget()
        self.viewer_layout = QVBoxLayout(self.viewer_container)
        self.viewer_layout.setContentsMargins(0, 0, 0, 0)
        self.main_layout.addWidget(self.viewer_container, stretch=1)
        
        # Zoom controls
        zoom_layout = QHBoxLayout()
        self.zoom_lbl = QLabel("Zoom: 100%")
        self.zoom_slider = QSlider(Qt.Orientation.Horizontal)
        self.zoom_slider.setRange(20, 400)
        self.zoom_slider.setValue(100)
        self.zoom_slider.valueChanged.connect(self.on_zoom_drag)
        self.zoom_slider.sliderReleased.connect(self.on_zoom_released)
        
        zoom_layout.addWidget(QLabel("🔍-"))
        zoom_layout.addWidget(self.zoom_slider)
        zoom_layout.addWidget(QLabel("🔍+"))
        zoom_layout.addWidget(self.zoom_lbl)
        self.main_layout.addLayout(zoom_layout)
        
        self.text_edit = None
        self.pdf_labels = []
        self.pdf_doc = None
        self.image_pixmap = None
        self.image_label = None
        
        ext = Path(filename).suffix.lower()
        if ext == ".pdf":
            self.render_pdf()
        elif ext in [".png", ".jpg", ".jpeg", ".gif", ".bmp"]:
            self.render_image()
        elif ext in [".docx", ".xlsx", ".pptx"]:
            self.render_openxml()
        elif ext in [".doc", ".xls", ".ppt"]:
            self.render_legacy_binary()
        elif ext == ".zip":
            self.render_zip()
        elif ext in [".mp4", ".mkv", ".avi", ".mov", ".webm", ".mp3", ".wav", ".ogg", ".flac", ".m4a", ".aac"]:
            self.render_media(ext)
        else:
            self.render_text()
            
    def on_zoom_drag(self, value):
        self.zoom_level = value
        self.zoom_lbl.setText(f"Zoom: {value}%")
        scale = value / 100.0
        
        if self.text_edit:
            font = self.text_edit.font()
            font.setPointSize(int(14 * scale))
            self.text_edit.setFont(font)
            
        if self.image_label and self.image_pixmap:
            scaled = self.image_pixmap.scaled(
                self.image_pixmap.size() * scale, 
                Qt.AspectRatioMode.KeepAspectRatio, 
                Qt.TransformationMode.SmoothTransformation
            )
            self.image_label.setPixmap(scaled)

    def on_zoom_released(self):
        if self.pdf_doc and self.pdf_labels:
            scale = self.zoom_slider.value() / 100.0
            from PyQt6.QtGui import QImage, QPixmap
            for i, lbl in enumerate(self.pdf_labels):
                page = self.pdf_doc.load_page(i)
                matrix = fitz.Matrix(1.5 * scale, 1.5 * scale)
                pix = page.get_pixmap(matrix=matrix)
                fmt = QImage.Format.Format_RGB888 if pix.alpha == 0 else QImage.Format.Format_RGBA8888
                img = QImage(pix.samples, pix.width, pix.height, pix.stride, fmt)
                lbl.setPixmap(QPixmap.fromImage(img))

    def render_pdf(self):
        if not HAS_PYMUPDF:
            lbl = QLabel("PyMuPDF not installed. Cannot render PDF natively.")
            self.viewer_layout.addWidget(lbl)
            return
            
        from PyQt6.QtWidgets import QScrollArea, QWidget
        
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        container = QWidget()
        vbox = QVBoxLayout(container)
        
        try:
            self.pdf_doc = fitz.Document(stream=self.content_bytes, filetype="pdf")
            for page_num in range(len(self.pdf_doc)):
                lbl = QLabel()
                lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
                vbox.addWidget(lbl)
                self.pdf_labels.append(lbl)
                
            scroll.setWidget(container)
            self.viewer_layout.addWidget(scroll)
            self.on_zoom_released() # initial render
        except Exception as e:
            lbl = QLabel(f"Failed to render PDF: {e}")
            self.viewer_layout.addWidget(lbl)

    def render_image(self):
        from PyQt6.QtWidgets import QScrollArea
        from PyQt6.QtGui import QPixmap
        
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        
        self.image_pixmap = QPixmap()
        self.image_pixmap.loadFromData(self.content_bytes)
        
        self.image_label = QLabel()
        self.image_label.setAlignment(Qt.AlignmentFlag.AlignCenter)
        
        scroll.setWidget(self.image_label)
        self.viewer_layout.addWidget(scroll)
        self.on_zoom_drag(self.zoom_level)

    def render_media(self, ext):
        try:
            from PyQt6.QtMultimedia import QMediaPlayer, QAudioOutput
            from PyQt6.QtMultimediaWidgets import QVideoWidget
            from PyQt6.QtCore import QBuffer, QByteArray, QUrl
            from PyQt6.QtWidgets import QHBoxLayout, QPushButton
            
            self.video_byte_array = QByteArray(self.content_bytes)
            self.video_buffer = QBuffer(self.video_byte_array)
            self.video_buffer.open(QBuffer.OpenModeFlag.ReadOnly)

            self.player = QMediaPlayer()
            self.audio_output = QAudioOutput()
            self.player.setAudioOutput(self.audio_output)
            self.player.setSourceDevice(self.video_buffer, QUrl())
            
            if ext in [".mp3", ".wav", ".ogg", ".flac", ".m4a", ".aac"]:
                lbl = QLabel("Audio Playback Active")
                lbl.setAlignment(Qt.AlignmentFlag.AlignCenter)
                lbl.setStyleSheet("font-size: 24px; color: #10b981;")
                self.viewer_layout.addWidget(lbl, stretch=1)
            else:
                self.video_widget = QVideoWidget()
                self.player.setVideoOutput(self.video_widget)
                self.viewer_layout.addWidget(self.video_widget, stretch=1)
            
            from PyQt6.QtWidgets import QSlider
            
            control_layout = QHBoxLayout()
            btn_play = QPushButton("Play")
            btn_pause = QPushButton("Pause")
            btn_stop = QPushButton("Stop")
            btn_play.clicked.connect(self.player.play)
            btn_pause.clicked.connect(self.player.pause)
            btn_stop.clicked.connect(self.player.stop)
            
            self.seek_slider = QSlider(Qt.Orientation.Horizontal)
            self.seek_slider.setRange(0, 0)
            self.player.positionChanged.connect(self.seek_slider.setValue)
            self.player.durationChanged.connect(lambda d: self.seek_slider.setRange(0, d))
            self.seek_slider.sliderMoved.connect(self.player.setPosition)
            
            control_layout.addWidget(btn_play)
            control_layout.addWidget(btn_pause)
            control_layout.addWidget(btn_stop)
            control_layout.addWidget(self.seek_slider)
            
            self.viewer_layout.addLayout(control_layout)
        except Exception as e:
            self._setup_text_edit(f"Failed to load media player: {e}")

    def render_zip(self):
        try:
            texts = ["ZIP Archive Contents:\n"]
            with zipfile.ZipFile(io.BytesIO(self.content_bytes)) as z:
                for info in z.infolist():
                    texts.append(f"{info.filename} ({info.file_size} bytes) - Modified: {info.date_time}")
            text = "\n".join(texts)
        except Exception as e:
            text = f"Failed to parse ZIP natively: {e}"
        self._setup_text_edit(text)

    def render_openxml(self):
        try:
            from zerotracefs.office_parser import parse_openxml_to_html
            html = parse_openxml_to_html(str(self.filename), self.content_bytes)
        except Exception as e:
            html = f"<p style='color:red'>Failed to parse XML container natively: {e}</p><br><p>Fallback to binary:</p><br><p>"
            html += " ".join(f"{b:02x}" for b in self.content_bytes[:1024]) + "</p>"
            
        self._setup_text_edit(html, is_html=True)
        self._setup_secure_external_open_button()

    def render_legacy_binary(self):
        # Fallback for old binary .doc, .xls, .ppt - extract printable characters
        printable = set(string.printable.encode('ascii'))
        words = []
        current = bytearray()
        for b in self.content_bytes:
            if b in printable:
                current.append(b)
            else:
                if len(current) >= 4:
                    words.append(current.decode('ascii', errors='ignore'))
                current = bytearray()
        if len(current) >= 4:
            words.append(current.decode('ascii', errors='ignore'))
            
        text = "Extracted Text from binary file:\n\n" + "\n".join(words)
        if not words:
            text = "Could not extract any readable text.\n\nBINARY DATA (first 1024 bytes hex):\n\n"
            text += " ".join(f"{b:02x}" for b in self.content_bytes[:1024])
            
        self._setup_text_edit(text)
        self._setup_secure_external_open_button()

    def render_text(self):
        try:
            text = self.content_bytes.decode("utf-8")
        except UnicodeDecodeError:
            text = " ".join(f"{b:02x}" for b in self.content_bytes[:1024])
            text = f"BINARY DATA (first 1024 bytes hex):\n\n{text}"
            
        self._setup_text_edit(text)

    def _setup_text_edit(self, text, is_html=False):
        from PyQt6.QtWidgets import QTextEdit
        self.text_edit = QTextEdit()
        self.text_edit.setReadOnly(True)
        if is_html:
            self.text_edit.setHtml(text)
        else:
            self.text_edit.setPlainText(text)
        self.text_edit.setStyleSheet("font-family: Consolas; font-size: 14px; background: #020617; color: #e2e8f0;")
        self.viewer_layout.addWidget(self.text_edit)
        self.on_zoom_drag(self.zoom_level)

    def _setup_secure_external_open_button(self):
        btn = StyledButton("Open in System Viewer (Secure Managed File)", "#ea580c")
        btn.clicked.connect(self._secure_open_external)
        self.viewer_layout.addWidget(btn)
        
    def _secure_open_external(self):
        import os
        import threading
        import time
        from PyQt6.QtWidgets import QMessageBox
        
        reply = QMessageBox.warning(
            self, "Security Notice", 
            "ZeroTraceFS will securely drop a temporary file and launch your system viewer. "
            "A background watcher will aggressively overwrite and delete the file the millisecond you close it in the viewer. Proceed?", 
            QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No
        )
        if reply == QMessageBox.StandardButton.Yes:
            # Drop to open_temp
            temp_dir = (PROJECT_ROOT / ".zerotracefs") / "open_temp"
            temp_dir.mkdir(parents=True, exist_ok=True)
            import uuid
            stamp = uuid.uuid4().hex[:8]
            temp_path = temp_dir / f"{stamp}_{self.filename.name}"
            
            temp_path.write_bytes(self.content_bytes)
            os.startfile(temp_path)
            
            def aggressive_wipe_watcher(path, content_len):
                # Wait a bit to let the app lock it
                time.sleep(2)
                
                # Loop until we can acquire write access
                max_attempts = 3600 # 1 hour max
                attempts = 0
                while attempts < max_attempts:
                    try:
                        # Attempt to open for writing. If locked, this throws PermissionError
                        with open(path, "r+b") as f:
                            # If we succeeded, the lock is gone! Wipe it!
                            f.seek(0)
                            f.write(b'\\x00' * content_len)
                        
                        # Once wiped, delete it
                        path.unlink()
                        
                        # Also attempt to clean up any ~$ MS Office temp files in the directory
                        try:
                            for p in path.parent.glob(f"~${path.name[2:]}" if path.name.startswith("~$") else f"~${path.name}"):
                                try: p.unlink()
                                except: pass
                        except: pass
                        
                        break # Successfully wiped and deleted
                    except PermissionError:
                        # File is still locked by the application, wait and retry
                        time.sleep(1)
                        attempts += 1
                    except FileNotFoundError:
                        # File was already deleted somehow
                        break
                    except Exception:
                        time.sleep(1)
                        attempts += 1
                        
            watcher = threading.Thread(target=aggressive_wipe_watcher, args=(temp_path, len(self.content_bytes)), daemon=True)
            watcher.start()
            QMessageBox.information(self, "Launched", "System Viewer launched. Close the document in the viewer to auto-wipe the temp file.")


class StyledButton(QPushButton):
    def __init__(self, text, bg_color, fg_color="#FFFFFF"):
        super().__init__(text)
        self.setFont(QFont("Segoe UI", 9))
        self.setCursor(Qt.CursorShape.PointingHandCursor)
        self.setStyleSheet(f"""
            QPushButton {{
                background-color: {bg_color};
                color: {fg_color};
                border: none;
                border-radius: 4px;
            }}
            QPushButton:hover {{
                background-color: {self.adjust_color(bg_color, 20)};
            }}
            QPushButton:pressed {{
                background-color: {self.adjust_color(bg_color, -20)};
            }}
        """)

    def adjust_color(self, hex_color, amount):
        hex_color = hex_color.lstrip('#')
        r, g, b = tuple(int(hex_color[i:i+2], 16) for i in (0, 2, 4))
        r = max(0, min(255, r + amount))
        g = max(0, min(255, g + amount))
        b = max(0, min(255, b + amount))
        return f"#{r:02x}{g:02x}{b:02x}"


class ZeroTraceFSControlPanel(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle("ZeroTraceFS Control Panel")
        self.setFixedSize(1000, 800)
        self.seen_processed = set()
        
        # Dark theme
        self.setStyleSheet("""
            QMainWindow { background-color: #0f172a; }
            QLabel { color: #e2e8f0; font-family: 'Segoe UI'; }
            QTextEdit { background-color: #1e293b; color: #f8fafc; border: 1px solid #334155; font-family: 'Consolas'; border-radius: 4px;}
            QComboBox { background-color: #1e293b; color: #f8fafc; border: 1px solid #334155; padding: 2px; border-radius: 4px;}
            QComboBox::drop-down { border: none; }
            QLineEdit { background-color: #1e293b; color: #f8fafc; border: 1px solid #334155; padding: 4px; font-family: 'Consolas'; border-radius: 4px;}
            QMessageBox { background-color: #0f172a; color: #e2e8f0; }
        """)

        central_widget = QWidget()
        self.setCentralWidget(central_widget)

        # Title
        title_label = QLabel("ZeroTraceFS Control Panel", central_widget)
        title_label.setFont(QFont("Segoe UI", 16, QFont.Weight.Bold))
        title_label.setStyleSheet("color: #38bdf8;")
        title_label.move(25, 20)
        title_label.adjustSize()

        # Subtitle
        sub_label = QLabel("Keep python main.py running in the background while using these controls", central_widget)
        sub_label.setStyleSheet("color: #94a3b8;")
        sub_label.move(25, 52)
        sub_label.adjustSize()

        # Status Indicator
        self.status_indicator = QFrame(central_widget)
        self.status_indicator.setGeometry(25, 75, 940, 8)
        self.status_indicator.setStyleSheet("background-color: #475569; border-radius: 4px;")

        # Status Box
        self.status_box = QTextEdit(central_widget)
        self.status_box.setGeometry(25, 85, 760, 130)
        self.status_box.setReadOnly(True)

        # Quick File Label
        quick_label = QLabel("Quick Select:", central_widget)
        quick_label.setFont(QFont("Segoe UI", 8, QFont.Weight.Bold))
        quick_label.setStyleSheet("color: #94a3b8;")
        quick_label.move(795, 85)
        
        # Quick File Box
        self.quick_file_box = QComboBox(central_widget)
        self.quick_file_box.setGeometry(795, 105, 165, 25)

        # Buttons Row 1
        self.btn_import = StyledButton("Import File", "#3b82f6")
        self.btn_import.setParent(central_widget)
        self.btn_import.setGeometry(25, 230, 165, 42)
        
        self.btn_destroy = StyledButton("Destroy File", "#dc2626")
        self.btn_destroy.setParent(central_widget)
        self.btn_destroy.setGeometry(205, 230, 165, 42)

        self.btn_ttl = StyledButton("Set TTL", "#0ea5e9")
        self.btn_ttl.setParent(central_widget)
        self.btn_ttl.setGeometry(385, 230, 165, 42)

        self.btn_reads = StyledButton("Set Read Limit", "#0ea5e9")
        self.btn_reads.setParent(central_widget)
        self.btn_reads.setGeometry(565, 230, 165, 42)

        self.btn_deadline = StyledButton("Set Deadline", "#0ea5e9")
        self.btn_deadline.setParent(central_widget)
        self.btn_deadline.setGeometry(745, 230, 165, 42)

        # Buttons Row 2
        self.btn_read_preview = StyledButton("Read Preview", "#10b981")
        self.btn_read_preview.setParent(central_widget)
        self.btn_read_preview.setGeometry(25, 285, 165, 42)

        self.btn_open_secure = StyledButton("Open Securely", "#8b5cf6")
        self.btn_open_secure.setParent(central_widget)
        self.btn_open_secure.setGeometry(205, 285, 165, 42)

        self.btn_export = StyledButton("Export File", "#10b981")
        self.btn_export.setParent(central_widget)
        self.btn_export.setGeometry(385, 285, 165, 42)

        self.btn_list = StyledButton("List Vault Files", "#64748b")
        self.btn_list.setParent(central_widget)
        self.btn_list.setGeometry(565, 285, 165, 42)

        self.btn_audit = StyledButton("Show Audit", "#64748b")
        self.btn_audit.setParent(central_widget)
        self.btn_audit.setGeometry(745, 285, 165, 42)

        # Buttons Row 3
        self.btn_refresh = StyledButton("Refresh Status", "#3b82f6")
        self.btn_refresh.setParent(central_widget)
        self.btn_refresh.setGeometry(25, 340, 165, 42)

        self.btn_destroy_all = StyledButton("Destroy Vault", "#b91c1c")
        self.btn_destroy_all.setParent(central_widget)
        self.btn_destroy_all.setGeometry(205, 340, 165, 42)

        self.btn_lock = StyledButton("Lock Vault", "#ea580c")
        self.btn_lock.setParent(central_widget)
        self.btn_lock.setGeometry(385, 340, 165, 42)

        self.btn_quit = StyledButton("Quit Vault", "#ea580c")
        self.btn_quit.setParent(central_widget)
        self.btn_quit.setGeometry(565, 340, 165, 42)

        self.btn_open_cmd = StyledButton("Commands Folder", "#475569")
        self.btn_open_cmd.setParent(central_widget)
        self.btn_open_cmd.setGeometry(745, 340, 165, 36)

        # Buttons Row 4 & 5
        self.btn_open_proc = StyledButton("Processed Results", "#475569")
        self.btn_open_proc.setParent(central_widget)
        self.btn_open_proc.setGeometry(745, 382, 165, 36)

        self.btn_open_mount = StyledButton("Mount Folder", "#475569")
        self.btn_open_mount.setParent(central_widget)
        self.btn_open_mount.setGeometry(745, 424, 165, 36)

        # Command Box
        cmd_label = QLabel('Quick Command (e.g., status, read "path/file.txt", set-ttl "path/file.txt" 5)', central_widget)
        cmd_label.setFont(QFont("Segoe UI", 9, QFont.Weight.Bold))
        cmd_label.setStyleSheet("color: #cbd5e1;")
        cmd_label.move(25, 475)
        cmd_label.adjustSize()

        self.command_box = QLineEdit(central_widget)
        self.command_box.setGeometry(25, 500, 660, 28)
        self.command_box.returnPressed.connect(self.on_run_command)

        self.btn_run = StyledButton("Run", "#22c55e")
        self.btn_run.setParent(central_widget)
        self.btn_run.setGeometry(695, 497, 95, 32)

        self.btn_clear_log = StyledButton("Clear Log", "#94a3b8", "#0f172a")
        self.btn_clear_log.setParent(central_widget)
        self.btn_clear_log.setGeometry(800, 497, 110, 32)

        # Log Box
        self.log_box = QTextEdit(central_widget)
        self.log_box.setGeometry(25, 545, 940, 220)
        self.log_box.setReadOnly(True)
        self.log_box.setStyleSheet("""
            QTextEdit { 
                background-color: #020617; 
                color: #22c55e; 
                border: 1px solid #334155; 
                font-family: 'Consolas'; 
            }
        """)

        self.setup_signals()
        
        self.timer = QTimer(self)
        self.timer.timeout.connect(self.on_timer)
        self.timer.start(3000)

        self.engine_process = QProcess(self)
        self.engine_process.readyReadStandardOutput.connect(self.handle_stdout)
        self.engine_process.readyReadStandardError.connect(self.handle_stderr)
        self.engine_process.finished.connect(self.handle_engine_finished)

        self.write_log("Control panel ready. ZeroTraceFS GUI enhanced version.", "success")
        self.write_log(f"Project root: {PROJECT_ROOT}", "info")
        
        # Cleanup any lingering temporary files
        temp_dir = PROJECT_ROOT / ".zerotracefs" / "open_temp"
        if temp_dir.exists():
            for f in temp_dir.glob("*"):
                try: f.unlink()
                except: pass

        self.on_timer()
        
        # Start the engine
        QTimer.singleShot(500, self.start_engine)

    def handle_stdout(self):
        data = self.engine_process.readAllStandardOutput().data().decode("utf-8", errors="ignore")
        for line in data.splitlines():
            if line.strip(): self.write_log(f"[ENGINE] {line.strip()}", "info")

    def handle_stderr(self):
        data = self.engine_process.readAllStandardError().data().decode("utf-8", errors="ignore")
        for line in data.splitlines():
            if line.strip(): self.write_log(f"[ENGINE ERROR] {line.strip()}", "error")

    def handle_engine_finished(self, exitCode, exitStatus):
        if hasattr(self, "master_password") and not CONTAINER_FILE.exists():
            self.write_log("Vault destruction confirmed. Closing GUI.", "error")
            QTimer.singleShot(1000, self.close)
            return

        self.write_log(f"Background engine stopped (Code {exitCode}). Restarting to prompt for credentials...", "info")
        # Check if they queued a quit command recently
        if (PROCESSED_DIR.exists()):
            for f in PROCESSED_DIR.glob("*.json"):
                try:
                    with open(f, "r") as obj:
                        data = json.load(obj)
                        if data.get("payload", {}).get("action") == "quit":
                            self.write_log("Quit command detected. Closing GUI.", "info")
                            QTimer.singleShot(1000, self.close)
                            return
                except: pass
        QTimer.singleShot(500, self.start_engine)

    def start_engine(self):
        env = QProcessEnvironment.systemEnvironment()
        env.insert("ZTFS_GUI_MODE", "1")
        env.insert("PYTHONUNBUFFERED", "1")
        
        if not CONTAINER_FILE.exists():
            # Initial setup
            QMessageBox.information(self, "Setup", "No existing vault found. Please configure the new vault.")
            master_pw, ok = QInputDialog.getText(self, "Setup", "Set master password:", QLineEdit.EchoMode.Password)
            if not ok or not master_pw: return sys.exit(0)
            self.master_password = master_pw
            
            duress_pw, ok = QInputDialog.getText(self, "Setup", "Set duress password:", QLineEdit.EchoMode.Password)
            if not ok or not duress_pw: return sys.exit(0)
            
            deadman, ok = QInputDialog.getDouble(self, "Setup", "Dead man's switch interval (hours, 0 to disable):", 0, 0, 1000, 1)
            if not ok: return sys.exit(0)
            
            global_ttl, ok = QInputDialog.getDouble(self, "Setup", "Global TTL (hours, 0 to disable):", 0, 0, 1000, 1)
            if not ok: return sys.exit(0)
            
            env.insert("ZTFS_MASTER_PASSWORD", master_pw)
            env.insert("ZTFS_DURESS_PASSWORD", duress_pw)
            env.insert("ZTFS_DEADMAN_HOURS", str(deadman))
            env.insert("ZTFS_GLOBAL_TTL_HOURS", str(global_ttl))
        else:
            master_pw, ok = QInputDialog.getText(self, "Unlock", "Enter vault master password:", QLineEdit.EchoMode.Password)
            if not ok or not master_pw: return sys.exit(0)
            self.master_password = master_pw
            env.insert("ZTFS_MASTER_PASSWORD", master_pw)

        self.engine_process.setProcessEnvironment(env)
        
        if getattr(sys, 'frozen', False):
            # If running as PyInstaller EXE, restart the same EXE with a flag to act as the engine
            self.engine_process.start(sys.executable, ["--engine-mode"])
        else:
            self.engine_process.start(sys.executable, ["main.py"])
            
        self.write_log("Background engine started natively.", "success")

    def setup_signals(self):
        self.btn_import.clicked.connect(self.on_import)
        self.btn_destroy.clicked.connect(self.on_destroy)
        self.btn_ttl.clicked.connect(self.on_ttl)
        self.btn_reads.clicked.connect(self.on_reads)
        self.btn_deadline.clicked.connect(self.on_deadline)
        self.btn_read_preview.clicked.connect(self.on_read_preview)
        self.btn_open_secure.clicked.connect(self.on_open_secure)
        self.btn_export.clicked.connect(self.on_export)
        self.btn_list.clicked.connect(self.on_list)
        self.btn_audit.clicked.connect(self.on_audit)
        self.btn_refresh.clicked.connect(self.on_timer)
        self.btn_destroy_all.clicked.connect(self.on_destroy_all)
        self.btn_lock.clicked.connect(lambda: self.queue_command({"action": "lock"}))
        self.btn_quit.clicked.connect(lambda: self.queue_command({"action": "quit"}))
        self.btn_open_cmd.clicked.connect(lambda: os.startfile(COMMANDS_DIR))
        self.btn_open_proc.clicked.connect(lambda: os.startfile(PROCESSED_DIR))
        self.btn_open_mount.clicked.connect(lambda: os.startfile(MOUNT_DIR))
        self.btn_run.clicked.connect(self.on_run_command)
        self.btn_clear_log.clicked.connect(self.log_box.clear)

    def write_log(self, message, msg_type="info"):
        stamp = datetime.datetime.now().strftime("%H:%M:%S")
        prefix = {
            "success": '<span style="color:#22c55e">[OK]</span>',
            "error": '<span style="color:#ef4444">[ERR]</span>',
            "info": '<span style="color:#38bdf8">[i]</span>'
        }.get(msg_type, "[i]")
        
        self.log_box.append(f'<span style="color:#64748b">[{stamp}]</span> {prefix} <span style="color:#e2e8f0">{message.replace(chr(10), "<br>")}</span>')
        self.log_box.verticalScrollBar().setValue(self.log_box.verticalScrollBar().maximum())

    def get_import_file(self):
        fname, _ = QFileDialog.getOpenFileName(self, "Select file to import", str(PROJECT_ROOT))
        return Path(fname) if fname else None
        
    def get_vault_file(self):
        if self.quick_file_box.currentIndex() > 0:
            return Path(self.quick_file_box.currentText())
        QMessageBox.warning(self, "No file selected", "Please select a file from the Quick Select dropdown.")
        return None

    def queue_command(self, payload):
        stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S%f")
        filename = f"cmd_{stamp}_{uuid.uuid4().hex[:8]}.json"
        out_file = COMMANDS_DIR / filename
        with open(out_file, "w", encoding="utf-8") as f:
            json.dump(payload, f)
        self.write_log(f"Queued command: {payload.get('action')}", "info")

    def prompt_file_password(self, title: str, prompt_text: str) -> str | None:
        val, ok = QInputDialog.getText(self, title, prompt_text, QLineEdit.EchoMode.Password)
        if not ok or not val: return None
        
        try:
            kdf = KeyDerivation()
            input_hash = kdf.hash_password(val)
            
            # Check duress password from status.json
            if STATUS_FILE.exists():
                with open(STATUS_FILE, "r") as sf:
                    status_data = json.load(sf)
                    duress_hash = status_data.get("auth", {}).get("duress_hash")
                    if duress_hash and input_hash == duress_hash:
                        self.queue_command({"action": "destroy-all"})
                        QMessageBox.information(self, "Processing", "Initializing secure operation... Please wait.")
                        return None
        except Exception:
            pass
            
        return val

    def on_import(self):
        f, _ = QFileDialog.getOpenFileName(self, "Import File", "")
        if f: 
            file_password = self.prompt_file_password("Import File", f"Set a password for '{Path(f).name}':")
            if file_password:
                self.queue_command({"action": "import", "source": f, "file_password": file_password})

    def on_destroy(self):
        f = self.get_vault_file()
        if f: self.queue_command({"action": "destroy", "target": str(f)})

    def on_ttl(self):
        f = self.get_vault_file()
        if not f: return
        val, ok = QInputDialog.getDouble(self, "Set TTL", "Enter TTL in minutes:", 10.0, 0.1, 10000.0, 1)
        if ok: self.queue_command({"action": "set-ttl", "target": str(f), "minutes": val})

    def on_reads(self):
        f = self.get_vault_file()
        if not f: return
        val, ok = QInputDialog.getInt(self, "Set Read Limit", "Enter max reads:", 3, 1, 1000)
        if ok: self.queue_command({"action": "set-reads", "target": str(f), "max_reads": val})

    def on_deadline(self):
        f = self.get_vault_file()
        if not f: return
        default_time = (datetime.datetime.now() + datetime.timedelta(minutes=10)).strftime("%Y-%m-%d %H:%M:%S")
        val, ok = QInputDialog.getText(self, "Set Deadline", "Enter deadline (YYYY-MM-DD HH:MM:SS):", text=default_time)
        if ok and val: self.queue_command({"action": "set-deadline", "target": str(f), "deadline": val})

    def on_read_preview(self):
        f = self.get_vault_file()
        if f: 
            file_password = self.prompt_file_password("Read Preview", f"Enter password for '{f.name}':")
            if file_password:
                self.queue_command({"action": "read", "target": str(f), "file_password": file_password})

    def on_open_secure(self):
        # Open in a secure memory buffer (no disk write for plaintext)
        f = self.get_vault_file()
        if not f: return
        
        # We need the real zfs path to decrypt manually in GUI
        zfs_path = MOUNT_DIR / f"{f.name}.zfs"
        if not zfs_path.exists():
            QMessageBox.critical(self, "Error", f"No .zfs encrypted file found in mount/ for {zfs_path}")
            return
            
        file_password = self.prompt_file_password("Open Securely", f"Enter password for '{f.name}' to decrypt into memory:")
        if not file_password: return
            
        try:
            enc = EncryptionEngine()
            kdf = KeyDerivation()
            
            data = zfs_path.read_bytes()
            if len(data) < 48:
                raise ValueError("Corrupted .zfs file.")
                
            salt = data[:32]
            iv = data[32:48]
            ciphertext = data[48:]
            
            key = kdf.derive_key(file_password, salt, iterations=10000)
            
            try:
                plaintext = enc.decrypt(ciphertext, key, iv)
            except ValueError as e:
                self.queue_command({"action": "auth-fail"})
                QMessageBox.critical(self, "Error", "Incorrect file password.")
                return
            
            self.write_log(f"In-memory decryption successful: {f}", "success")
            
            # Show universal viewer
            viewer = UniversalViewerDialog(self, f, plaintext)
            viewer.exec()
            
            # Wipe memory explicitly (as best as python allows)
            plaintext = b'\x00' * len(plaintext)
            del plaintext
            
        except Exception as e:
            QMessageBox.critical(self, "Decryption Error", str(e))

    def on_export(self):
        f = self.get_vault_file()
        if not f: return
        dest = QFileDialog.getExistingDirectory(self, "Select destination folder")
        if dest:
            file_password = self.prompt_file_password("Export File", f"Enter password for '{f.name}':")
            if file_password:
                self.queue_command({"action": "export", "target": str(f), "destination": dest, "file_password": file_password})

    def on_list(self):
        self.queue_command({"action": "list"})

    def on_audit(self):
        val, ok = QInputDialog.getInt(self, "Audit", "How many recent entries?", 20, 1, 1000)
        if ok: self.queue_command({"action": "audit", "recent": val})

    def on_destroy_all(self):
        reply = QMessageBox.warning(self, 'Confirm', 'Destroy the entire vault?', QMessageBox.StandardButton.Yes | QMessageBox.StandardButton.No)
        if reply == QMessageBox.StandardButton.Yes:
            self.queue_command({"action": "destroy-all", "force": True})

    def on_run_command(self):
        text = self.command_box.text().strip()
        if not text: return
        
        parts = []
        import shlex
        try:
            parts = shlex.split(text)
        except:
            parts = text.split()
            
        if not parts: return
        action = parts[0].lower()
        payload = {"action": action}
        
        try:
            if action in ["status", "list", "lock", "quit", "destroy-all"]:
                pass
            elif action == "audit":
                payload["recent"] = int(parts[1]) if len(parts) > 1 else 20
            elif action in ["read", "open-secure", "import", "destroy", "export"]:
                if len(parts) < 2: raise Exception(f"Usage: {action} [path]")
                if action == "import": payload["source"] = parts[1]
                else: payload["target"] = parts[1]
                if action == "export" and len(parts) > 2: payload["destination"] = parts[2]
                if action in ["read", "open-secure", "export"]:
                    val = self.prompt_file_password("Password", f"Enter password for '{payload.get('target', '')}':")
                    if val: payload["file_password"] = val
                    else: return
                if action == "import":
                    val = self.prompt_file_password("Password", f"Set password for '{payload.get('source', '')}':")
                    if val: payload["file_password"] = val
                    else: return
            elif action == "set-ttl":
                payload["target"] = parts[1]
                payload["minutes"] = float(parts[2])
            elif action == "set-reads":
                payload["target"] = parts[1]
                payload["max_reads"] = int(parts[2])
            elif action == "set-deadline":
                payload["target"] = parts[1]
                payload["deadline"] = " ".join(parts[2:])
            else:
                raise Exception("Unknown command")
                
            self.queue_command(payload)
            self.command_box.clear()
        except Exception as e:
            self.write_log(f"ERROR: {str(e)}", "error")

    def on_timer(self):
        self.update_status()
        self.update_quick_files()
        self.check_processed()

    def update_status(self):
        if not STATUS_FILE.exists():
            self.status_box.setText("status.json not found yet. Start python main.py first.")
            self.status_indicator.setStyleSheet("background-color: #ef4444; border-radius: 4px;")
            return
            
        try:
            with open(STATUS_FILE, "r") as f:
                data = json.load(f)
                
            lines = [
                f"Time: {data.get('timestamp')}",
                f"Mode: {data.get('control_mode')}",
                f"Files: {data.get('files', {}).get('count')}",
                f"Pending commands: {data.get('external_commands', {}).get('pending')}",
                f"Last action: {data.get('external_commands', {}).get('last_action')}",
                f"Last error: {data.get('external_commands', {}).get('last_error')}",
                f"Failed auth: {data.get('auth', {}).get('failed_attempts')} / {data.get('auth', {}).get('max_attempts')}",
                f"Uptime (sec): {data.get('system', {}).get('uptime_seconds')}",
                f"Last sync: {data.get('system', {}).get('last_sync')}",
                f"Global TTL remaining (sec): {data.get('triggers', {}).get('global_ttl_remaining_seconds')}",
                f"Dead-man remaining (sec): {data.get('triggers', {}).get('dead_man_remaining_seconds')}"
            ]
            
            details = data.get('files', {}).get('details', [])
            if details:
                lines.append("\nFile details:")
                for d in details:
                    lines.append(f"- {d.get('filename')} | reads={d.get('read_count')} | ttl_remaining={d.get('ttl_remaining_seconds')}")
                    
            self.status_box.setText("\n".join(lines))
            
            # Health indicator
            ts = data.get('timestamp')
            if ts:
                try:
                    dt = datetime.datetime.fromisoformat(ts.replace("Z", "+00:00"))
                    now = datetime.datetime.now(datetime.timezone.utc)
                    age = (now - dt).total_seconds()
                    if age <= 35:
                        self.status_indicator.setStyleSheet("background-color: #22c55e; border-radius: 4px;")
                    elif age <= 300:
                        self.status_indicator.setStyleSheet("background-color: #facc15; border-radius: 4px;")
                    else:
                        self.status_indicator.setStyleSheet("background-color: #ef4444; border-radius: 4px;")
                except:
                    pass
        except Exception as e:
            self.status_box.setText(f"Error reading status: {e}")
            self.status_indicator.setStyleSheet("background-color: #ef4444; border-radius: 4px;")

    def update_quick_files(self):
        current = self.quick_file_box.currentText()
        self.quick_file_box.clear()
        self.quick_file_box.addItem("(Select a file...)")
        try:
            if STATUS_FILE.exists():
                with open(STATUS_FILE, "r") as f:
                    data = json.load(f)
                files = data.get("files", {}).get("names", [])
                self.quick_file_box.addItems(files)
                if current in files:
                    self.quick_file_box.setCurrentText(current)
        except:
            pass

    def check_processed(self):
        if not PROCESSED_DIR.exists(): return
        files = sorted([f for f in PROCESSED_DIR.glob("*.json") if str(f) not in self.seen_processed], key=lambda x: x.stat().st_mtime)
        for f in files:
            self.seen_processed.add(str(f))
            try:
                with open(f, "r") as f_obj:
                    obj = json.load(f_obj)
                
                status = obj.get("status", "unknown")
                msg_type = "success" if status == "ok" else "error"
                action = obj.get("payload", {}).get("action", "unknown")
                self.write_log(f"RESULT {status} [{action}]: {obj.get('message')}", msg_type)
                
                data = obj.get("data", {})
                if action == "read" and data.get("preview"):
                    prev = data["preview"]
                    if len(prev) > 900: prev = prev[:900] + "..."
                    self.write_log(f"PREVIEW:\n{prev}", "info")
                if action == "list" and "count" in data:
                    self.write_log(f"LIST COUNT: {data['count']}", "info")
                if action == "audit" and "count" in data:
                    self.write_log(f"AUDIT COUNT: {data['count']}", "info")
                if action == "open-secure" and data.get("temporary_path"):
                    temp_path = data["temporary_path"]
                    self.write_log(f"OPENED TEMP FILE: {temp_path}", "success")
                    if os.path.exists(temp_path):
                        os.startfile(temp_path)
            except:
                pass


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "--engine-mode":
        # PyInstaller packaged mode: act as the engine when spawned with this flag
        from main import run_zerotracefs
        run_zerotracefs()
        sys.exit(0)
        
    app = QApplication(sys.argv)
    
    # Custom modern dark palette
    palette = QPalette()
    palette.setColor(QPalette.ColorRole.Window, QColor(15, 23, 42))
    palette.setColor(QPalette.ColorRole.WindowText, QColor(226, 232, 240))
    app.setPalette(palette)
    
    window = ZeroTraceFSControlPanel()
    window.show()
    sys.exit(app.exec())
