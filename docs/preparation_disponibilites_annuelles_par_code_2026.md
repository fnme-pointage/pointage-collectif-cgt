# Pointage collectif CGT - preparation des disponibilites annuelles par unite et par code

Statut : **SPECIFICATION PREPARATOIRE - NON DEPLOYEE**  
Decision utilisateur : suivi collectif **par unite, annee et code** ; deux sorties CSV (recapitulatif annuel enrichi et bilan dedie).  
Date de preparation : 15 novembre 2026.  
Perimetre : application GitHub Pages `fnme-pointage/pointage-collectif-cgt`, Supabase `Fnme pointage`.  
AUCUNE operation sur les donnees de production et AUCUNE publication depuis cette branche.

## 1. Objectif fonctionnel

Renseigner une quantite d'heures annuelles disponibles par code et par unite, sans affectation individuelle. Pour une combinaison (unite, annee, code) :

- `pointes_seconds` = somme des secondes des pointages de l'annee, rattachees a **l'unite du pointage**, independamment de l'unite actuelle de l'utilisateur.
- `disponibles_seconds` = enveloppe annuelle saisie, ou valeur absente (= non renseignee).
- `restantes_seconds` = `disponibles_seconds - pointes_seconds` si une enveloppe est renseignee.
- `taux_consommation` = `pointes_seconds / disponibles_seconds * 100` si disponibilite strictement positive.
- disponibilite = 0 et pointes > 0 : signaler depassement sans calculer de pourcentage trompeur.
- disponibilite absente : afficher "Non renseigne" et solde / taux non calculables, jamais 0.
- disponibilite = 0 et pointes = 0 : afficher solde = 0, taux "—" (base nulle).

Les soldes negatifs sont autorises et affiches comme un depassement. L'application ne doit **jamais** bloquer un pointage pour cette raison.

## 2. Etat du systeme verifie (15-11-2026)

- `index.html` : rubrique "Suivi annuel" avec selecteur `annualYear`, grille `summaryTable` et boutons `exportSummary`, `exportRaw`.
- Fonction `annualReport()` : calcule `codeTotals` en sommant les `duration_seconds` (repli historique sur `hours`). Fonction `reportTable()` termine par "Total par code".
- `exportSummary` : CSV annuel unite; `exportRaw` : detail annuel.
- `exportDivisionPeriod` : CSV annuel et mensuel division, isole les lignes par `user_id|unit_id` pour respecter les mutations.
- `globalSummaryRows` : exports nationaux et multi-divisions, distingue l'unite du pointage; `exportGlobalSummary` et `exportSelectedDivisions` l'utilisent.
- Les exports mensuels existent, mais la fonctionnalite nouvelle concerne les **exports annuels** seulement : ne pas modifier les exports mensuels.
- `month_codes` : `id`, `unit_id`, `month_key`, `code`, `label`, `catalogue_id`. Inspection : 2592 lignes, aucun `catalogue_id` manquant, 27 identifiants de catalogue; aucun changement de code texte par identifiant et unite actuellement detecte.
- `entries` : `unit_id`, `month_key`, `code_id`, `saved_code`, `saved_label`, `duration_seconds`, `hours`.
- Unites actives : ULM, OPF, UFPI, FLAMANVILLE et unite technique ADMIN. Ne **jamais** creer d'enveloppe pour l'unite technique ADMIN.
- Divisions : DTEAM, DPN.

## 3. Emplacement et formulaire

Dans le suivi annuel, inserer une section repliable par defaut :
**"Disponibilites et consommation des heures"**.

Dans les espaces d'administration nationale, de responsable de division et de responsable d'unite :
- selection de l'annee (meme annee que le suivi annuel), et unite selon droits;
- bouton "Saisir / modifier les heures disponibles" ouvrant un tableau de saisie;
- colonnes "Code", "Libelle", "Heures disponibles", "Heures pointees", "Heures restantes", "Consommation";
- toutes les valeurs saisies par code, pas par utilisateur;
- heures au format decimal FR, saisie `HH:MM` eventuellement admise; utiliser une validation explicite et conversion en **secondes entieres**;
- champs vides = absence de dotation; 0 = 0 heure;
- ne pas initialiser automatiquement l'annee suivante avec les dotations de l'annee precedente;
- inclure les codes actifs et les codes historiques de l'annee meme s'ils ont ete desactives ensuite;
- conserver la saisie en cours et avertir avant un changement d'unite / d'annee si non enregistree;
- enregistrer atomiquement et recharger la valeur apres enregistrement;
- montrer "Modifie le ... par ..." sans exposer de donnees aux comptes non habilites.

Le selecteur d'annees doit supporter une enveloppe deja renseignee meme si aucun pointage n'existe encore pour cette annee. Pas de creation de mois de pointage lors de la saisie des disponibilites.

## 4. Schema prevu (migration SQL A REDIGER ET TESTER EN ENVIRONNEMENT ISOLE, PAS EN PRODUCTION)

Table dediee `public.pointage_annual_code_availability` :

| Colonne | Type / controle |
|---|---|
| `unit_id` | UUID FK vers `public.units.id` |
| `year` | integer, plage valide raisonnable |
| `catalogue_id` | UUID FK vers `public.pointage_code_catalogue.id` |
| `available_seconds` | bigint >= 0, NOT NULL pour une ligne enregistree |
| `updated_by` | UUID FK vers `auth.users.id` |
| `updated_at` | timestamptz |
| `revision` | entier >0 pour detecter les sauvegardes concurrentes |

Contrainte unique / cle primaire : `(unit_id, year, catalogue_id)`. L'absence de ligne signifie "non renseigne" ; supprimer une enveloppe = remettre dans cet etat via action explicite, avec audit.

Table de journalisation `public.pointage_annual_code_availability_audit` : `unit_id`, `year`, `catalogue_id`, ancienne valeur, nouvelle valeur, auteur, date, type d'action. Lecture uniquement par responsables habilites et administrateur.

Aucun champ ajoute ni modifie dans les tables `entries`, `month_codes`, `months`, `profiles`, `units`.

### Resolution identite de code

- Utiliser `catalogue_id` comme identifiant stable de dotation; recuperer depuis `month_codes` pour les pointages historiques.
- Ne pas joindre uniquement sur le texte du libelle; il peut changer.
- Pour les exports existants actuellement groupes par `code` texte : verifier a la sauvegarde/export qu'une meme identite de code n'a pas ete renommee au cours de l'annee. Si oui, neutraliser le calcul du solde par colonne ambigue et afficher une alerte de controle; ne jamais attribuer une meme dotation deux fois.
- Si une saisie historique ne permet pas de retrouver un `catalogue_id`, la signaler explicitement au lieu de la perdre ou de l'attribuer arbitrairement.
- Rejouer les tests apres toute evolution du catalogue, en particulier en cas de reutilisation d'un ancien code sous un autre identifiant.

## 5. Autorisations

- **Admin national actif** : lecture/ecriture de toutes les unites non techniques, consultation nationale, unites, divisions et multi-divisions.
- **Responsable de division actif** : lecture/ecriture des unites actives de sa division uniquement, synthese de sa division.
- **Responsable d'unite actif** : lecture/ecriture uniquement de son unite.
- **Utilisateur ordinaire** et `anon` : aucun acces aux enveloppes ou au journal.

Verifier cote serveur et pas seulement dans l'interface. Employer RLS et des droits SQL explicites. Reutiliser avec precaution les fonctions deja disponibles `pointage_is_admin()` et `pointage_manager_unit_allowed(unit_id)`; garantir aussi le statut actif de l'administrateur. Toute fonction supplementaire privilegiee devra etre placee dans un schema interne non expose, avec controle d'identite et d'habilitation. Ne pas utiliser `user_metadata` pour les droits, ni donner de `service_role` au navigateur.

Les controles de portee doivent s'appliquer aux consultations, exports, ecritures, corrections et historique. Une modification de division ou un retrait de responsabilite prend effet cote serveur a la prochaine requete.

## 6. Exports retenus

### A. Recapitulatif annuel enrichi (CSV existant)

Conserver exactement l'entete et toutes les lignes "agent" existantes. Apres "Total par code", ajouter :
- "Heures disponibles";
- "Heures restantes";
- "Taux de consommation".

Unite : ajouter les 3 lignes pour l'unite et l'annee consultees.

Division : calculer la disponibilite par **somme des enveloppes des unites** de la division; additionner les pointages de ces unites selon `entries.unit_id`, sans les reappliquer dans l'unite actuelle de l'agent.

National / plusieurs divisions : conserver le perimetre choisi et les lignes existantes, puis ajouter les 3 lignes consolidees sans inclure ADMIN et sans compter une enveloppe deux fois.

Lorsque des enveloppes manquent pour un code et un perimetre multi-unites, afficher "Incomplet" plutot qu'un total de disponibilites partiel presente comme complet. Une enveloppe connue pour une unite sans pointage demeure comptabilisee. En cas d'ambiguite de code historique, afficher "A verifier".

La colonne "Total heures" ne doit pas afficher de pourcentage et ne doit pas presenter comme complet un montant avec des codes non renseignes. La ligne des heures pointes reste identique au CSV actuel.

Conserver les noms et l'ordre des exports annuels actuels, ne pas affecter les exports mensuels ou les exports individuels.

### B. Export dedie : "Bilan des disponibilites annuelles par code" (nouveau CSV)

Colonnes recommandees :
`Annee ; Division ; Unite ; Code ; Libelle ; Heures disponibles ; Heures pointees ; Heures restantes ; Taux de consommation ; Etat`.

- Une ligne par code et unite; lignes sans enveloppe affichees explicitement.
- Pour une division, ajouter un sous-total de division par code; pour l'admin national, sous-totaux par division et total national par code.
- Si plusieurs divisions sont selectionnees, uniquement celles-ci.
- Colonnes en heures decimales comme dans le CSV existant, separateur `;` et BOM UTF-8.
- Etats : "Disponible", "Non renseigne", "Depassement", "Code historique a verifier", "Incomplete consolidations" selon les cas.
- Eviter l'export de noms ou d'identifiants d'agents dans ce bilan dedie, puisque le besoin est collectif.
- Recalculer les pointages et disponibilites au moment du clic (pas de snapshot ancien).

## 7. Cas de test obligatoires avant publication

1. Aucune enveloppe en base : tous les anciens exports restent identiques (hors 3 nouvelles lignes uniquement dans les annuels), tous les nouveaux soldes "Non renseigne".
2. 300 h disponibles, 215 h pointe es => 85 h restantes, 71,666... %.
3. 0 h disponibles, 5 h pointees => solde -5 h et depassement, pourcentage non calcule.
4. Pas de pointage, 120 h disponibles => solde 120 h.
5. Mutation entre 2 unites : les heures sont rattachees uniquement a `entries.unit_id`.
6. Utilisateur inactif avec pointages historiques : heures conservees dans les totaux deja existants.
7. Code inactif avec heures historiques et disponibilite : visible.
8. Changement de libelle : bonne association via `catalogue_id`.
9. Changement de code texte / code recycle : controle explicite, aucun double compte.
10. Division DTEAM, DPN, perimetre national et selection de plusieurs divisions : consolidation exacte.
11. Tentative ecriture par utilisateur ordinaire / acces hors division : refus SQL/RLS.
12. Saisie concurrente de 2 responsables : refus de la revision obsolete, pas d'ecrasement silencieux.
13. Montants en heures/minutes, decimales FR, valeurs neg atives ou mal formatees : validation correcte.
14. Page sur mobile et PC : formulaires adaptes, pas de debordement horizontal bloquant.
15. Regression : exports CSV details / recap / mensuels, creation et gestion de comptes, codes, messages flash, saisie pointages, fermeture mois, maintenances inalteres.
16. Une annee sans mois de pointage doit etre utilisable pour saisir une disponibilite sans creer 12 mois.
17. Aucune fuite de donnees de la table ou du journal via `anon`.
18. Plan de repli : revenir au code initial tout en preservant les disponibilites deja creees; migration additive seulement.

## 8. Ordre de travail propose

1. Completer un script de migration non destructif + RLS + audit dans une branche de travail; verifier le SQL sur une copie de test.
2. Implementer le formulaire et son comportement repliable, sans changer la saisie des pointages.
3. Construire une fonction pure de consolidation disponibilites/pointages, testee avec fixtures (unite, mutation, codes historiques).
4. Ajouter les 3 lignes aux exports annuels existants en preservant les lignes deja produites.
5. Ajouter l'export CSV dedie et verifier les sous-totaux division/nation.
6. Tester les droits SQL puis navigation PC/mobile et les non-regressions.
7. Ne fusionner sur `main`, ne migrer le Supabase de production et ne publier GitHub Pages **qu'apres validation explicite de la mise en oeuvre**.

## 9. Points de vigilance connus

- Les exports nationaux utilisent `globalSummaryRows`; apres ajout de lignes, les messages actuellement fondes sur `rows.length-2` devront etre corriges pour ne pas annoncer trois utilisateurs de plus.
- L'annee disponible doit etre affichee meme si aucun `months` n'existe pour elle.
- La comptabilisation conserve les secondes (et non une conversion arrondie a chaque saisie).
- Ne pas introduire une seconde allocation au niveau des divisions : **une seule source de verite par unite/code/annee**.
- Le recapitulatif annuel doit continuer a identifier une meme personne par unite de pointage lorsqu'il s'agit d'une mutation.
- Ne pas multiplier les extractions lourdes : recuperer les dotations sur un seul lot par perimetre et annee.

Fin de la specification preparatoire.
