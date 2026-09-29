{ lib
, python3Packages
, qt6
, openconnect
}:

let
  pyproject = lib.importTOML ../pyproject.toml;
in
python3Packages.buildPythonApplication {
  pname = "openconnect-sso";
  inherit (pyproject.tool.poetry) version;
  pyproject = true;

  src = lib.fileset.toSource {
    root = ../.;
    fileset = lib.fileset.unions [
      ../pyproject.toml
      ../README.md
      ../openconnect_sso
    ];
  };

  build-system = [ python3Packages.poetry-core ];

  dependencies = with python3Packages; [
    attrs
    colorama
    keyring
    lxml
    prompt-toolkit
    pyotp
    pyqt6
    pyqt6-webengine
    pysocks
    pyxdg
    requests
    structlog
    toml
  ];

  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  buildInputs = [ qt6.qtbase qt6.qtwebengine ];

  # Wrap the Python entry points (not just ELF/Mach-O binaries) with the Qt environment,
  # and put openconnect on PATH for the default (non --authenticate) mode.
  dontWrapQtApps = true;
  preFixup = ''
    makeWrapperArgs+=(
      "''${qtWrapperArgs[@]}"
      --prefix PATH : ${lib.makeBinPath [ openconnect ]}
    )
  '';

  pythonImportsCheck = [ "openconnect_sso" ];
  # The test suite needs a display and network access.
  doCheck = false;

  meta = {
    description = pyproject.tool.poetry.description;
    homepage = "https://github.com/vseredovych/openconnect-sso";
    license = lib.licenses.gpl3Only;
    mainProgram = "openconnect-sso";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
