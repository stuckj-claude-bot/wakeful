{
  lib,
  python3Packages,
  qt6,
  kdePackages,
  version,
  src,
}:

python3Packages.buildPythonApplication {
  pname = "wakeful";
  inherit version src;
  pyproject = true;

  build-system = [ python3Packages.setuptools ];
  dependencies = [ python3Packages.pyqt6 ];

  nativeBuildInputs = [ qt6.wrapQtAppsHook ];
  # qtsvg draws the SVG icons; qtwayland is the native Plasma 6 platform.
  buildInputs = [
    qt6.qtbase
    qt6.qtsvg
    qt6.qtwayland
  ];

  # The version lives in src/wakeful/__init__.py; stamp the flake's into it the
  # way the deb/rpm build does, so the two cannot disagree.
  postPatch = ''
    substituteInPlace src/wakeful/__init__.py \
      --replace-fail "$(grep '^__version__' src/wakeful/__init__.py)" '__version__ = "${version}"'
  '';

  dontWrapQtApps = true;
  # kreadconfig6/kwriteconfig6 enable the lid option; on Plasma they are on the
  # PATH already, but the service units below start with a minimal one.
  preFixup = ''
    makeWrapperArgs+=(
      "''${qtWrapperArgs[@]}"
      --prefix PATH : ${lib.makeBinPath [ kdePackages.kconfig ]}
    )
  '';

  postInstall = ''
    install -Dm644 data/wakeful.desktop $out/share/applications/wakeful.desktop
    install -Dm644 src/wakeful/icons/wakeful.svg $out/share/icons/hicolor/scalable/apps/wakeful.svg
    install -Dm644 docs/wakeful.1 $out/share/man/man1/wakeful.1
  '';

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];
  # The D-Bus tests need a session bus and stand-in services; CI runs them.
  disabledTestPaths = [ "tests/integration" ];
  pythonImportsCheck = [ "wakeful.block" ];

  meta = {
    description = "KDE Plasma tray app that keeps the computer awake for a set time";
    homepage = "https://github.com/stuckj/wakeful";
    license = lib.licenses.mit;
    mainProgram = "wakeful";
    platforms = lib.platforms.linux;
  };
}
