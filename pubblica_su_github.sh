#!/bin/zsh
# Collega il kit al repository GitHub e lo carica.
# Uso: ./pubblica_su_github.sh https://github.com/<utente>/PrinterKit
set -e
cd "${0:A:h}"
URL="${1%.git}"
if [[ ! "$URL" =~ '^https://github\.com/([A-Za-z0-9_.-]+)/([A-Za-z0-9_.-]+)$' ]]; then
  echo "Indirizzo non valido. Esempio: ./pubblica_su_github.sh https://github.com/mario/PrinterKit"
  exit 1
fi
REPO="${match[1]}/${match[2]}"
if [[ "${match[1]}" == (TUO-UTENTE|UTENTE|NOME-VERO) ]]; then
  echo "Al posto di ${match[1]} va il tuo nome utente GitHub (lo vedi nell'indirizzo del repository)."
  exit 1
fi
# Prima di toccare qualsiasi file: il repository deve esistere ed essere raggiungibile con il token.
if ! git ls-remote "$URL.git" >/dev/null 2>&1; then
  echo "Il repository $URL non esiste oppure il token non ha accesso a questo repository."
  echo "Apri il repository su github.com e copia l'indirizzo dalla barra del browser."
  exit 1
fi

# config.json: catalogo, ricette e "Segnala su GitHub" puntano al repository.
sed -i '' -E "s#githubusercontent\.com/[^/]+/[^/]+/#githubusercontent.com/$REPO/#g; s#\"githubRepo\": \"[^\"]*\"#\"githubRepo\": \"$REPO\"#" config.json
grep -q "$REPO" config.json || { echo "config.json non aggiornato"; exit 1; }
git add config.json
git diff --cached --quiet || git commit -q -m "Collega il kit al repository $REPO"

git remote remove origin 2>/dev/null || true
git remote add origin "$URL.git"
echo "Carico su $URL ..."
echo "Se chiede la password, incolla un token GitHub (non la password dell'account): vedi le istruzioni ricevute."
git push -u origin main
echo
echo "Fatto. Prossimi passi: docs/MESSA_IN_FUNZIONE.md (punti 3, 4 e 6)."
