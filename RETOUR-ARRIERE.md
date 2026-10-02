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

## Évolution du blocage pour maintenance

Avant la suppression de l'onglet Mois, le commit 02cdb31e60924a7efac6fdca2c3d1f57e4ed3801 a été conservé dans la branche backup/2026-10-01-avant-maintenance. Les données concernées (heures, mois, codes et versions du catalogue) et les fonctions ont également été copiées dans le schéma privé pointage_backup_20261001_maintenance.

Le bouton « Bloquer les saisies pour maintenance » est global, quelle que soit l'unité affichée. Son état est conservé en base. Il devient « Réactiver les saisies » une fois le blocage confirmé. Les utilisateurs gardent accès à la consultation et aux documents ; l'administrateur continue de modifier le catalogue et les autres paramètres.

Les enregistrements sont protégés en base, via la fonction d'enregistrement et les écritures directes sur les tables de pointage. L'activation attend la fin des transactions d'enregistrement déjà engagées. L'interface vérifie le blocage toutes les 15 secondes, au retour sur la page et avant un enregistrement. Les modifications non enregistrées restent dans la page pendant le blocage ; elles ne sont pas une sauvegarde et il faut garder la page ouverte pour les reprendre après la maintenance.

Pour revenir à la version avec l'onglet Mois, restaurer index.html depuis la branche backup/2026-10-01-avant-maintenance, renouveler le cache de sw.js et republier. Vérifier d'abord que le blocage est désactivé. Si nécessaire, l'administrateur peut le désactiver depuis le bouton actuel ou un administrateur de base peut exécuter : update public.pointage_maintenance set locked=false where id=true;
Les tables et les protections de maintenance restent compatibles avec l'ancienne interface. Aucune restauration des heures n'est nécessaire.

Les tests d'interface couvrent aussi l'arrivée du blocage pendant une saisie, le refus côté serveur après l'ouverture du formulaire, la conservation des heures non enregistrées, la reprise et le bouton administrateur. Le fichier tests/maintenance_database.sql vérifie le refus des insertions, modifications et suppressions de pointages, l'impossibilité pour un utilisateur de débloquer l'application, la disponibilité du catalogue administrateur et la reprise des saisies, dans une transaction annulée.


## Formats de durée — 1er octobre 2026

La branche `backup/avant-formats-durees-20261001` conserve l’interface précédente. Les pointages précédant le changement sont sauvegardés dans la table privée `pointage_private.entries_before_time_formats_20261001` et l’ancienne fonction d’enregistrement dans `pointage_private.time_formats_rpc_backup`. Ces sauvegardes ne sont pas accessibles aux utilisateurs.

Les durées exactes sont désormais stockées dans `entries.duration_seconds`. Le champ `hours` est conservé à deux décimales pour les anciens clients ; il ne doit plus être utilisé seul pour les totaux précis. Un ancien client qui renvoie une valeur décimale inchangée conserve la précision existante. Les exports de la nouvelle interface utilisent les secondes.

Un retour à l’ancienne interface conserve les données, mais cette interface affichera et exportera les heures arrondies à deux décimales. Privilégier une correction de l’interface actuelle si des durées en minutes ont été saisies. Ne pas supprimer la colonne `duration_seconds` ni restaurer la table de sauvegarde sur les données actuelles : cela supprimerait les nouvelles saisies.


## Liste type indépendante — 2 octobre 2026

ADMIN > Catalogue des codes contient une liste type modifiable pour les futures unités. Les 26 codes d’origine ont été copiés dans `pointage_code_template`. Chaque création d’unité copie la liste type dans les versions propres à cette unité, dans la même transaction. Modifier la liste type ne modifie pas les unités existantes ; leurs catalogues restent indépendants. La lecture et l’enregistrement sont réservés à l’administrateur et une révision empêche l’écrasement d’une modification concurrente.

La définition antérieure de l’initialisation des années et la liste d’origine sont conservées dans `pointage_private.code_template_initial_backup`, inaccessible aux utilisateurs. Le commit précédent conserve l’interface sans l’éditeur de liste type. En cas de retour de l’interface, conserver les nouvelles tables et le déclencheur pour que les nouvelles unités continuent de recevoir la liste type enregistrée. Ne pas restaurer les catalogues ou les pointages depuis une ancienne sauvegarde.


## Ajouts nationaux à toutes les unités — 2 octobre 2026

ADMIN > Catalogue des codes propose la liste type et l’application des seuls codes ajoutés ou modifiés à toutes les unités actives, à partir du mois choisi. Les modifications individuelles restent dans les onglets d’unité. `pointage_save_national_codes` enregistre la liste type et les versions des unités dans une transaction unique. Un conflit annule toute l’opération. Les codes locaux non concernés et les pointages restent conservés ; les mois fermés ne sont pas synchronisés.

La case d’application à toutes les unités est cochée par défaut. Décochée, elle limite l’enregistrement à la liste type des futures unités. L’ancien éditeur de liste type reste compatible avec les tables : revenir à un ancien commit d’interface ne supprime pas les codes nationaux déjà ajoutés ni leurs données.
