@echo off
rem Builds record_session.exe and generate_template.exe (PyInstaller onefile).
rem Needs Python 3.12 x64 (py launcher). paramiko is pinned to 3.5.1: 4.x/5.x
rem dropped diffie-hellman-group1/14-sha1 and ssh-rsa, which older switches need.
setlocal
cd /d "%~dp0"
py -3.12 -m venv .venv || exit /b 1
.venv\Scripts\python -m pip install -q -r requirements.txt || exit /b 1
.venv\Scripts\pyinstaller --onefile --console --clean --noconfirm --name record_session ^
  --version-file ver-record_session.txt --exclude-module tkinter record_session.py || exit /b 1
.venv\Scripts\pyinstaller --onefile --console --clean --noconfirm --name generate_template ^
  --version-file ver-generate_template.txt --exclude-module tkinter generate_template.py || exit /b 1
echo Built: dist\record_session.exe dist\generate_template.exe
