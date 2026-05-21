import os
import re
import subprocess
from functools import wraps
from pathlib import Path

from flask import Flask, flash, redirect, render_template, request, send_from_directory, session, url_for

app = Flask(__name__)

# Security configuration
LAB_MODE = os.environ.get("LAB_MODE", "secure")  # set to 'vulnerable' to enable the original unsafe behavior
SECURE_COOKIES = os.environ.get("SECURE_COOKIES", "1") == "1"

app.secret_key = os.environ.get("SECRET_KEY", os.urandom(24).hex())
portal_token = os.environ.get("DEV_PORTAL_TOKEN", "REPLACE_ME_AT_RUNTIME")

app.config.update(
    SESSION_COOKIE_HTTPONLY=True,
    SESSION_COOKIE_SECURE=SECURE_COOKIES,
    SESSION_COOKIE_SAMESITE="Lax",
)

phase2_flag_path = Path("/app/flags/phase2.txt")
phase2_flag = phase2_flag_path.read_text(encoding="utf-8").strip() if phase2_flag_path.exists() else "VulnOS{phase2_missing}"


def login_required(view):
    @wraps(view)
    def wrapper(*args, **kwargs):
        if not session.get("authed"):
            return redirect(url_for("login"))
        return view(*args, **kwargs)

    return wrapper


@app.route("/")
def index():
    if session.get("authed"):
        return redirect(url_for("portal"))
    return redirect(url_for("login"))


@app.route("/.env.bak")
def leaked_backup():
    return send_from_directory(app.static_folder or "/app/static", ".env.bak", mimetype="text/plain")


@app.route("/login", methods=["GET", "POST"])
def login():
    if request.method == "POST":
        token = request.form.get("token", "").strip()
        if token == portal_token:
            session["authed"] = True
            flash("Portal unlocked.", "success")
            return redirect(url_for("portal"))
        flash("Invalid token.", "error")
    return render_template("login.html")


@app.route("/logout")
def logout():
    session.clear()
    flash("Session cleared.", "info")
    return redirect(url_for("login"))


@app.route("/portal", methods=["GET", "POST"])
@login_required
def portal():
    output = None
    target = ""

    if request.method == "POST":
        target = request.form.get("ip", "").strip()
        if LAB_MODE == "vulnerable":
            # Original vulnerable behavior: passed directly into a shell
            command = f"ping -c 1 {target}"
            try:
                output = subprocess.check_output(
                    command,
                    shell=True,
                    text=True,
                    stderr=subprocess.STDOUT,
                    timeout=8,
                )
            except subprocess.CalledProcessError as exc:
                output = exc.output or str(exc)
            except subprocess.TimeoutExpired:
                output = "Diagnostic timed out."
        else:
            # Safe mode: validate and call ping without a shell
            if not re.match(r'^[A-Za-z0-9.\-]{1,255}$', target):
                output = "Invalid target."
            else:
                try:
                    output = subprocess.check_output([
                        "ping",
                        "-c",
                        "1",
                        target,
                    ], text=True, stderr=subprocess.STDOUT, timeout=8)
                except subprocess.CalledProcessError as exc:
                    output = exc.output or str(exc)
                except subprocess.TimeoutExpired:
                    output = "Diagnostic timed out."

    return render_template("portal.html", output=output, target=target, phase2_flag=phase2_flag)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000, debug=False)
