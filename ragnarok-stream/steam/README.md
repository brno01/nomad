# Alternativa com Steam Input (não usada; exige conta Steam)

Estes arquivos (`add_shortcut.py`, `enable_xbox_support.py`, `build_layout.py`, `ragnarok-apex3.vdf`, `INSTALL-LAYOUT.md`) montam o atalho não-Steam "Ragnarok (stream)" com layout do Steam Input. O fluxo atual **não usa nada daqui**: o jogo abre com `umu-run` (`../umu/`) e o controle é traduzido pelo AntiMicroX (`../antimicrox/`), sem conta Steam. Os testes (`../tests/test_add_shortcut.py`, `test_layout.py`, `test_xbox_support.py`) continuam rodando; o instalador `scripts/ragnarok-stream-install.sh` não os chama.
