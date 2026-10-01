# Sauvegarde du 1er octobre 2026

Avant les changements, le code a été conservé dans la branche `backup/2026-10-01-avant-annees-catalogue`, au commit `4c33a5373324d2758969c3500ea7e77284ba33cc`.

Les données des tables months, month_codes, entries, submissions, profiles, units et pointage_documents ainsi que les définitions des fonctions et les règles d'accès ont été copiées dans le schéma privé `pointage_backup_20261001` de Supabase. Les sauvegardes sont inaccessibles aux utilisateurs de l'application. Elles contiennent 14 mois, 364 codes mensuels, 7 saisies (223,62 heures) et 6 profils au moment de la copie. Les fichiers PDF, l'authentification et la configuration des notifications n'ont pas été modifiés par cette évolution et ne sont pas inclus dans cette copie des données.

## Revenir à l'ancienne interface

Demander à restaurer la version sauvegardée du 1er octobre suffit. La procédure préparée est `scripts/rollback-interface.sh`, puis publication du commit produit sur main. Elle restaure index.html et sw.js et renouvelle le cache Android.

Ce retour conserve les pointages, les comptes et les unités, y compris ceux ajoutés depuis la sauvegarde. Les colonnes et les tables ajoutées dans Supabase restent compatibles avec l'ancienne interface. Le nouvel enregistrement des heures conserve les références historiques et reste compatible avec l'ancien client. Il n'est pas nécessaire de restaurer la base entière.

La restauration intégrale des données anciennes n'est pas la procédure habituelle : elle ferait perdre les saisies ou modifications postérieures à la sauvegarde. Pour une restauration intégrale, comparer d'abord les tables actuelles et les copies, puis définir précisément les lignes à récupérer.

## Fonctionnement de la nouvelle version

L'année en cours s'affiche par défaut. Le champ Année permet d'accéder aux douze mois de toute autre année. Les mois et leurs listes de codes sont partagés par unité, jamais dupliqués pour chaque utilisateur. Leur création est automatique lors de l'ouverture de l'année. Les heures restent personnelles.

L'administrateur gère le Catalogue des codes : code, libellé, document de référence, activation et date d'application (mois en cours ou futur). Il choisit une ou plusieurs unités concernées. Les changements sont enregistrés en une transaction. Les mois fermés restent inchangés ; les versions s'appliquent aussi aux futurs mois lors de leur ouverture. Une nouvelle unité reçoit le catalogue standard initial ; les modifications spécifiques déjà effectuées dans les autres unités ne lui sont pas copiées automatiquement.

Les pointages enregistrés conservent le code, le libellé et le document du moment de leur première saisie, même après une mise à jour de leurs heures. Les exports annuels utilisent ces codes historiques. Une désactivation retire un code des nouvelles saisies tout en permettant de conserver les lignes déjà enregistrées.

## Vérifications

`tests/catalogue_database.sql` vérifie dans une transaction annulée la création des douze mois, l'isolation des unités, l'accès administrateur, la propagation aux mois futurs, le rejet des doublons et la conservation des références historiques. `tests/catalogue_ui.cjs` vérifie l'interface mobile et administrateur avec des données simulées. Ces tests d'interface ne constituent pas une connexion réelle à un compte utilisateur.
