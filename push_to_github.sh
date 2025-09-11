#!/bin/bash

echo "🚀 Script de Push GitHub - Algo Poseidon"
echo "======================================="
echo ""

# Vérifier qu'on est dans le bon répertoire
if [ ! -f "TEST CLAUDE AMELIORATION.mq5" ]; then
    echo "❌ Erreur: Fichier MQ5 non trouvé. Assurez-vous d'être dans le bon répertoire."
    exit 1
fi

echo "📁 Répertoire correct détecté"
echo ""

# Demander les identifiants GitHub
echo "🔑 Identifiants GitHub requis:"
read -p "👤 Username GitHub: " github_username
echo ""
read -s -p "🔐 Token/Password GitHub: " github_password
echo ""
echo ""

echo "🔄 Tentative de push vers GitHub..."
echo ""

# Configurer git avec les identifiants (temporairement)
git remote set-url origin "https://${github_username}:${github_password}@github.com/tradingluca31-boop/algo-poseidon.git"

# Effectuer le push
if git push origin main; then
    echo ""
    echo "✅ SUCCESS! Push vers GitHub réussi!"
    echo "🌐 Ton EA modifié est maintenant sur GitHub!"
    echo ""
    echo "🔗 Lien: https://github.com/tradingluca31-boop/algo-poseidon"
else
    echo ""
    echo "❌ Erreur lors du push. Vérifiez vos identifiants."
    echo "💡 Astuce: Utilisez un Personal Access Token au lieu du mot de passe"
    echo "📖 Guide: https://docs.github.com/en/github/authenticating-to-github/creating-a-personal-access-token"
fi

# Remettre l'URL sans identifiants pour la sécurité
git remote set-url origin "https://github.com/tradingluca31-boop/algo-poseidon.git"

echo ""
echo "🔒 Identifiants effacés pour la sécurité"
echo "🏁 Script terminé"