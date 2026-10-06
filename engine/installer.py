"""
Managed by easy-deploy @VERSION@ -- do not edit. Refresh it with
`init.sh --update` from an easy-deploy checkout.

Builds this project's Python environment, the same way on a workstation, in CI
and on the server:

  1. env/ next to this file (python -m venv), and VIRTUAL_ENV, ACTIVATE_SCRIPT
     and PYTHON_EXECUTABLE in .env
  2. python-dotenv, then requirements.txt, retrying a package that fails to
     build on its own
  3. the project's validation step, with env/'s python: any module it imports
     that is still missing is reported -- and, when a person is at the
     keyboard, installed

    python3 installer.py                                 interactive
    python3 installer.py --non-interactive               what deploy.sh, install.sh and CI run
    python3 installer.py --check "Nebula/manage.py check"
    python3 installer.py --check none

--check is the validation step: arguments for env/'s python, run from this
directory. Without it, manage.py (here or one directory down) gets
`manage.py check`, which imports every installed app; otherwise main.py is
imported -- not run, so a server's entry point cannot block the installer.

--non-interactive never prompts and never installs a guessed package name: a
module the validation step cannot import fails the run, with the name to add
to requirements.txt. On a server nobody is there to confirm that `import jwt`
meant PyJWT and not the unrelated `jwt` on PyPI.
"""

import argparse
import os
import shlex
import subprocess
import sys


ROOT = os.path.dirname(os.path.abspath(__file__))
NON_INTERACTIVE = False
CHECK_TIMEOUT = 300


"""
1. Retrieval
"""


def retreive_venv_path():
    return os.getenv("VIRTUAL_ENV")

def retreive_activate_script_path():
    return os.getenv("ACTIVATE_SCRIPT")

def retreive_python_executable_path():
    return os.getenv("PYTHON_EXECUTABLE")


RESET = "\033[0m"
BOLD = "\033[1m"
WHITE = "\033[97m"
YELLOW = "\033[93m"
RED = "\033[91m"
GREEN = "\033[92m"
CYAN = "\033[96m"


def stylize(message, color=WHITE, bold=False):
    prefix = BOLD if bold else ""
    return f"{prefix}{color}{message}{RESET}"


PACKAGE_NAME_ALIASES = {
    "slack_bolt": "slack-bolt",
    "dotenv": "python-dotenv",
    "PIL": "Pillow",
    "cv2": "opencv-python",
    "yaml": "PyYAML",
    "sklearn": "scikit-learn",
    "Crypto": "pycryptodome",
    "bs4": "beautifulsoup4",
}


def normalize_package_name(package_name):
    cleaned_name = package_name.strip().strip("'\"")
    return PACKAGE_NAME_ALIASES.get(cleaned_name, cleaned_name)


def get_venv_python_executable(venv_path=None):
    if not venv_path:
        venv_path = retreive_venv_path()

    if not venv_path:
        venv_path = get_local_venv_path()

    if venv_path:
        if os.name == "nt":
            return os.path.join(venv_path, "Scripts", "python.exe")
        return os.path.join(venv_path, "bin", "python")

    return retreive_python_executable_path() or sys.executable


def get_local_venv_path():
    local_venv_path = os.path.join(locate_dir(), "env")
    if os.path.exists(local_venv_path):
        return local_venv_path
    return None


def get_local_venv_python_executable():
    local_venv_path = get_local_venv_path()
    if local_venv_path:
        return identify_venv_python_executable(local_venv_path)
    return get_venv_python_executable()


def parse_missing_module_from_output(output_text):
    if not output_text:
        return None

    markers = ["No module named", "ModuleNotFoundError:"]
    for marker in markers:
        marker_index = output_text.rfind(marker)
        if marker_index == -1:
            continue

        line_break_index = output_text.find("\n", marker_index)
        line_text = output_text[marker_index:] if line_break_index == -1 else output_text[marker_index:line_break_index]

        if "No module named" in line_text:
            fragment = line_text.split("No module named", 1)[1].strip()
            fragment = fragment.strip(":").strip()
            fragment = fragment.strip("\"'")

            if "." in fragment:
                fragment = fragment.split(".", 1)[0].strip()

            if fragment:
                return fragment

        if "ModuleNotFoundError:" in line_text and "No module named" in line_text:
            fragment = line_text.split("No module named", 1)[1].strip().strip(":").strip().strip("\"'")
            if "." in fragment:
                fragment = fragment.split(".", 1)[0].strip()
            if fragment:
                return fragment

    return None


def extract_problematic_package_from_pip_output(output_text):
    if not output_text:
        return None

    last_collected_package = None
    for raw_line in output_text.splitlines():
        line = raw_line.strip()

        if line.startswith("Collecting "):
            package_fragment = line.split("Collecting ", 1)[1].strip()
            package_fragment = package_fragment.split(" ", 1)[0].strip()
            package_fragment = package_fragment.split("(", 1)[0].strip()
            if package_fragment:
                last_collected_package = normalize_package_name(package_fragment)

        if "Could not build wheels for" in line:
            package_fragment = line.rsplit("for", 1)[1].strip().strip(".")
            if package_fragment:
                return normalize_package_name(package_fragment)

        if "Failed to build" in line:
            package_fragment = line.split("Failed to build", 1)[1].strip().strip(":")
            if package_fragment:
                return normalize_package_name(package_fragment)

        if "Preparing metadata" in line and "for" in line:
            package_fragment = line.rsplit("for", 1)[1].strip().strip("...")
            if package_fragment:
                last_collected_package = normalize_package_name(package_fragment)

    if last_collected_package and any(keyword in output_text.lower() for keyword in ["metadata-generation-failed", "subprocess-exited-with-error", "error:"]):
        return last_collected_package

    return None


def is_package_not_found_output(output_text):
    if not output_text:
        return False

    lowered_output = output_text.lower()
    return (
        "could not find a version that satisfies the requirement" in lowered_output
        or "no matching distribution found for" in lowered_output
        or "no module named" in lowered_output
    )


def prompt_for_package_name(failed_name):
    normalized_name = normalize_package_name(failed_name)
    if NON_INTERACTIVE:
        return None
    print(stylize(f"[INPUT] Unable to resolve {failed_name}", YELLOW, bold=True))
    print(stylize(f"[INPUT] Suggested pip package: {normalized_name}", CYAN, bold=True))
    print(stylize("[INPUT] Enter a pip package name to install, or press Enter to accept the suggested name.", WHITE))
    try:
        user_value = input("Package name: ").strip()
    except EOFError:
        return None
    if user_value:
        return user_value
    return normalized_name


def run_pip_install(package_name, python_executable=None):
    python_executable = python_executable or get_venv_python_executable()
    process = subprocess.run(
        [python_executable, "-m", "pip", "install", "--disable-pip-version-check", package_name],
        capture_output=True,
        text=True,
    )

    if process.stdout:
        print(process.stdout, end="")
    if process.stderr:
        print(process.stderr, end="")

    combined_output = (process.stdout or "") + "\n" + (process.stderr or "")
    return process.returncode == 0, combined_output


def run_pip_install_requirements(python_executable=None):
    python_executable = python_executable or get_venv_python_executable()
    process = subprocess.run(
        [python_executable, "-m", "pip", "install", "--disable-pip-version-check", "-r", requirements_path()],
        capture_output=True,
        text=True,
    )

    if process.stdout:
        print(process.stdout, end="")
    if process.stderr:
        print(process.stderr, end="")

    combined_output = (process.stdout or "") + "\n" + (process.stderr or "")
    return process.returncode == 0, combined_output


def install_package_with_user_retry(package_name, python_executable=None):
    current_name = normalize_package_name(package_name)
    python_executable = python_executable or get_venv_python_executable()

    while True:
        cli_step(f"Installing package {stylize(current_name, CYAN, bold=True)}")
        success, output_text = run_pip_install(current_name, python_executable)

        if success:
            cli_ok(f"Successfully installed {stylize(current_name, CYAN, bold=True)}")
            return current_name

        if is_package_not_found_output(output_text):
            cli_warn(f"Package {stylize(current_name, CYAN, bold=True)} was not found")
            current_name = prompt_for_package_name(current_name)
            if not current_name:
                return None
            continue

        cli_error(f"Failed to install {stylize(current_name, CYAN, bold=True)}")
        print(output_text, end="" if output_text.endswith("\n") else "\n")
        return None


def cli_banner():
    print(stylize("\n" + "=" * 60, WHITE, bold=True))
    print(stylize(f"{os.path.basename(locate_dir())} | Installer", WHITE, bold=True))
    print(stylize("=" * 60, WHITE, bold=True))

def cli_step(message):
    print(stylize(f"\n[INFO] {message}", WHITE))

def cli_ok(message):
    print(stylize(f"[OK] {message}", GREEN, bold=True))

def cli_warn(message):
    print(stylize(f"[WARN] {message}", YELLOW, bold=True))

def cli_error(message):
    print(stylize(f"[ERROR] {message}", RED, bold=True))


"""
2. Package Installation
"""


def install_package(package_name):
    try:
        python_executable = get_local_venv_python_executable()
        return install_package_with_user_retry(package_name, python_executable)
    except subprocess.CalledProcessError as e:
        cli_error(f"Failed to install {package_name}. Error: {e}")
        return None

def requirements_path():
    return os.path.join(locate_dir(), "requirements.txt")

def check_requirements_txt_exists():
    return os.path.exists(requirements_path())

def install_packages_from_requirements():
    if not check_requirements_txt_exists():
        cli_warn("requirements.txt not found. Skipping bulk installation.")
        return None
    python_executable = get_local_venv_python_executable()
    retry_packages = set()

    for attempt in range(1, 4):
        cli_step(f"Installing dependencies from requirements.txt (attempt {attempt}/3)")
        success, output_text = run_pip_install_requirements(python_executable)

        if success:
            cli_ok("Successfully installed packages from requirements.txt.")
            return True

        problem_package = extract_problematic_package_from_pip_output(output_text)
        if problem_package and problem_package not in retry_packages:
            retry_packages.add(problem_package)
            cli_warn(f"Detected failing package {stylize(problem_package, CYAN, bold=True)}")
            cli_step(f"Trying to install {stylize(problem_package, CYAN, bold=True)} directly")
            install_package_with_user_retry(problem_package, python_executable)
            continue

        if "numpy" in output_text.lower() and "numpy" not in retry_packages:
            retry_packages.add("numpy")
            cli_warn(f"Detected failing package {stylize('numpy', CYAN, bold=True)}")
            cli_step(f"Trying to install {stylize('numpy', CYAN, bold=True)} directly")
            install_package_with_user_retry("numpy", python_executable)
            continue

        cli_error("Failed to install packages from requirements.txt")
        return False

    cli_error("Failed to install packages from requirements.txt after multiple attempts")
    return False


CHECK_COMMAND = None  # set by main(): a list of arguments for env/'s python, or [] for none

def detect_check_command():
    """manage.py here or one directory down gets Django's system check; otherwise main.py is imported"""
    subdirs = sorted(d for d in os.listdir(locate_dir()) if d not in ("env", ".git", "node_modules"))
    for manage in ["manage.py"] + [os.path.join(d, "manage.py") for d in subdirs]:
        if os.path.isfile(os.path.join(locate_dir(), manage)):
            return [manage, "check"]
    if os.path.isfile(os.path.join(locate_dir(), "main.py")):
        return ["-c", "import main"]
    return []

def try_run():
    """runs the validation step; a missing package surfaces here. Returns (passed, missing module or None)"""
    if not CHECK_COMMAND:
        cli_ok("No validation step for this project.")
        return True, None
    shown = " ".join(shlex.quote(part) for part in CHECK_COMMAND)
    try:
        cli_step(f"Validating project with: python {shown}")
        result = subprocess.run(
            [get_local_venv_python_executable(), *CHECK_COMMAND],
            capture_output=True, text=True, cwd=locate_dir(), timeout=CHECK_TIMEOUT,
        )
    except subprocess.TimeoutExpired:
        cli_error(f"python {shown} was still running after {CHECK_TIMEOUT}s. A validation step has to finish:")
        cli_error("set one that does with --check (PY_CHECK in deploy/easy-deploy.conf).")
        return False, None
    except Exception as e:
        cli_error(f"Unexpected error occurred: {e}")
        return False, None

    if result.returncode == 0:
        cli_ok(f"python {shown} passed.")
        return True, None

    combined_output = (result.stdout or "") + "\n" + (result.stderr or "")
    package_name = parse_missing_module_from_output(combined_output)

    if package_name:
        cli_warn(f"Missing module detected: {package_name}")
        return False, package_name

    cli_error(f"python {shown} failed")
    if result.stdout:
        print(result.stdout)
    if result.stderr:
        print(result.stderr)
    return False, None

def install_dotenv():
    package_name = "python-dotenv"
    return install_package(package_name)


"""
3. Virtual Environment and dotenv Handling
"""


def locate_dir():
    return ROOT

def create_env():
    directory = locate_dir()
    venv_name = "env"
    venv_path = os.path.join(directory, venv_name)

    if not os.path.exists(venv_path):
        cli_step(f"Creating virtual environment at: {venv_path}")
        subprocess.check_call([sys.executable, "-m", "venv", venv_path])
        cli_ok("Virtual environment created.")
    else:
        cli_ok(f"Virtual environment already exists at: {venv_path}")

    return venv_path

def check_activation_script_exists(venv_path):
    return os.path.exists(os.path.join(venv_path, "Scripts", "activate.bat")) or os.path.exists(os.path.join(venv_path, "bin", "activate"))

def set_dotenv_value(key, value):
    """sets KEY=value in .env: replaces the line if there is one, appends it if not, leaves every other line alone"""
    dotenv_path = os.path.join(locate_dir(), ".env")
    lines = []
    if os.path.exists(dotenv_path):
        with open(dotenv_path) as f:
            lines = f.read().splitlines()
    wanted = f"{key}={value}"
    found = False
    for index, line in enumerate(lines):
        if line.split("=", 1)[0].strip() == key:
            if not found:
                lines[index] = wanted
            else:
                lines[index] = None  # a duplicate an older installer appended
            found = True
    lines = [line for line in lines if line is not None]
    if not found:
        lines.append(wanted)
    with open(dotenv_path, "w") as f:
        f.write("\n".join(lines) + "\n")

def add_env_to_dotenv(venv_path):
    cli_step("Writing VIRTUAL_ENV to .env")
    set_dotenv_value("VIRTUAL_ENV", venv_path)
    cli_ok("VIRTUAL_ENV saved.")

def identify_activate_script_path(venv_path):
    if os.name == "nt":
        return os.path.join(venv_path, "Scripts", "activate.bat")
    else:
        return os.path.join(venv_path, "bin", "activate")


def add_activate_script_to_dotenv(venv_path):
    cli_step("Writing ACTIVATE_SCRIPT to .env")
    set_dotenv_value("ACTIVATE_SCRIPT", identify_activate_script_path(venv_path))
    cli_ok("ACTIVATE_SCRIPT saved.")

def identify_venv_python_executable(venv_path):
    if os.name == "nt":
        return os.path.join(venv_path, "Scripts", "python.exe")
    else:
        return os.path.join(venv_path, "bin", "python")

def add_python_executable_to_dotenv(venv_path):
    cli_step("Writing PYTHON_EXECUTABLE to .env")
    set_dotenv_value("PYTHON_EXECUTABLE", identify_venv_python_executable(venv_path))
    cli_ok("PYTHON_EXECUTABLE saved.")

def venv_handling():
    cli_step("Preparing virtual environment")
    venv_path = create_env()
    add_env_to_dotenv(venv_path)
    add_activate_script_to_dotenv(venv_path)
    add_python_executable_to_dotenv(venv_path)
    cli_ok("Virtual environment setup complete.")

def check_and_install_dotenv():
    """checked in env/, which is where the project imports it from"""
    probe = subprocess.run([get_local_venv_python_executable(), "-c", "import dotenv"], capture_output=True)
    if probe.returncode == 0:
        cli_ok("python-dotenv is already installed.")
        return True
    cli_warn("python-dotenv is not installed. Installing now.")
    return install_dotenv() is not None

def installation_handling():
    cli_step("Starting package installation")
    if check_requirements_txt_exists():
        if install_packages_from_requirements() is False:
            return False

    attempted = set()
    while True:
        passed, missing_package = try_run()
        if passed:
            break
        if not missing_package:
            return False
        if missing_package in attempted:
            cli_error(f"{missing_package} is still missing after installing it; stopping rather than looping.")
            return False
        attempted.add(missing_package)
        suggestion = normalize_package_name(missing_package)
        if NON_INTERACTIVE:
            cli_error(f"The project imports {missing_package}, which is not installed.")
            cli_error(f"Add it to requirements.txt (the package is probably {suggestion}).")
            return False
        cli_step(f"Resolving missing dependency: {missing_package}")
        if not install_package_with_user_retry(missing_package):
            return False
        cli_warn(f"Installed {suggestion}, which requirements.txt does not list: add it there.")

    cli_ok("Package installation phase complete.")
    return True


def main(argv=None):
    global NON_INTERACTIVE, CHECK_COMMAND

    parser = argparse.ArgumentParser(description="Build this project's Python environment in env/.")
    parser.add_argument("--non-interactive", action="store_true",
                        help="never prompt, never install a guessed package name (deploys, CI)")
    parser.add_argument("--check", metavar="ARGS",
                        help='the validation step, as arguments for env/\'s python ("none" for none)')
    args = parser.parse_args(argv)

    NON_INTERACTIVE = args.non_interactive or not sys.stdin.isatty()
    if args.check is None:
        CHECK_COMMAND = detect_check_command()
    elif args.check.strip().lower() in ("", "none"):
        CHECK_COMMAND = []
    else:
        CHECK_COMMAND = shlex.split(args.check)

    cli_banner()
    cli_step("Starting setup")
    venv_handling()
    ok = check_and_install_dotenv() and installation_handling()
    if not ok:
        cli_error("Setup failed.")
        print("=" * 60 + "\n")
        return 1
    cli_ok("Setup finished successfully.")
    print("=" * 60 + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
