# Raptor AI — Orange Pi 4 Pro

Sistema di videosorveglianza con rilevamento intelligente (NPU), per la scheda Orange Pi 4 Pro.

## Installazione

Sulla scheda appena accesa, con il sistema operativo che forniamo noi, come utente `orangepi` (non servono permessi di root): un solo comando.

```
curl -fsSL https://raw.githubusercontent.com/Federiko78/Raptor-Ai-OrangePi4Pro-Ver.0.16.10/Ai/install/raptor-00-verifica.sh | bash
```

Controlla che la scheda vada bene — sistema operativo, kernel, memoria, spazio, NPU, rete — e dice se si può procedere. Non installa e non cambia nulla.

> Il link "Source code" che vedi nella pagina della release è generato automaticamente da GitHub: non serve per l'installazione, si può ignorare.

## Cosa c'è in questo repository

La cartella [`install/`](install/) contiene gli script di installazione e manutenzione, documentati in [`install/LEGGIMI.txt`](install/LEGGIMI.txt).
