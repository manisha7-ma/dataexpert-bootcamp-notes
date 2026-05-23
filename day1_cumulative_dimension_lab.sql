--Create Struct to have in the Temporal Info of the Player
CREATE TYPE SEASON_STATS AS (
	SEASON INTEGER,
	GP INTEGER,
	PTS REAL,
	REB REAL,
	AST REAL
)
----------------------------------------------------------------------------------------------------------
-- New Table Structure 
CREATE TABLE PLAYERS (
	PLAYER_NAME TEXT,
	HEIGHT TEXT,
	COLLEGE TEXT,
	COUNTRY TEXT,
	DRAFT_YEAR TEXT,
	DRAFT_NUMBER INTEGER,
	SEASON_STATS SEASON_STATS[],
	CURRENT_SEASON INTEGER
)
----------------------------------------------------------------------------------------------------------
-- First year to start with 
select min(season) from player_seasons 
--1996

-------------------------------------------------------------------------------------------------------
-- So to begin with the TODAY and YESTERDAY concept : YESTERDAY to begin with : 1995
WITH
	YESTERDAY AS (
		SELECT
			*
		FROM
			PLAYERS
		WHERE
			CURRENT_SEASON = 1995
	),
	TODAY AS (
		SELECT
			*
		FROM
			PLAYER_SEASONS
		WHERE
			SEASON = 1996
			-- SEED QUERY 
			-- BASCIALLY STARTING POINT OF BUILDING THE TABLE 
	)
SELECT
	*
FROM
	TODAY AS T
	FULL OUTER JOIN YESTERDAY AS Y ON Y.PLAYER_NAME = T.PLAYER_NAME

--------------------------------------------------------------------------------------------------
INSERT INTO
	PLAYERS (
		PLAYER_NAME,
		HEIGHT,
		COLLEGE,
		COUNTRY,
		DRAFT_YEAR,
		DRAFT_NUMBER,
		SEASON_STATS,
		CURRENT_SEASON
	)
WITH
	YESTERDAY AS (
		SELECT
			*
		FROM
			PLAYERS
		WHERE
			CURRENT_SEASON = 1999
	),
	TODAY AS (
		SELECT
			*
		FROM
			PLAYER_SEASONS
		WHERE
			SEASON = 2000
	)
SELECT
	COALESCE(T.PLAYER_NAME, Y.PLAYER_NAME) AS PLAYER_NAME,
	COALESCE(T.HEIGHT, Y.HEIGHT) AS HEIGHT,
	COALESCE(T.COLLEGE, Y.COLLEGE) AS COLLEGE,
	COALESCE(T.COUNTRY, Y.COUNTRY) AS COUNTRY,
	COALESCE(T.DRAFT_YEAR, Y.DRAFT_YEAR) AS DRAFT_YEAR,
	COALESCE(T.DRAFT_NUMBER, Y.DRAFT_NUMBER) AS DRAFT_NUMBER,
	CASE
		WHEN Y.CURRENT_SEASON IS NULL THEN ARRAY[
			ROW (T.SEASON, T.GP, T.PTS, T.REB, T.AST)::SEASON_STATS
		]
		WHEN T.SEASON IS NOT NULL THEN Y.SEASON_STATS || ARRAY[
			ROW (T.SEASON, T.GP, T.PTS, T.REB, T.AST)::SEASON_STATS
		]
		ELSE Y.SEASON_STATS
	END AS SEASON_STATS,
	COALESCE(T.SEASON, Y.CURRENT_SEASON + 1) AS CURRENT_SEASON
FROM
	TODAY AS T
	FULL OUTER JOIN YESTERDAY AS Y ON Y.PLAYER_NAME = T.PLAYER_NAME
SELECT
	*
FROM
	PLAYERS
WHERE
	CURRENT_SEASON = 2000
	-------------------------------------------------------------------------------------------------------
	--Flattening the Players to look like the player_seasons 
	-- Use OF UNNEST ()
WITH
	CTE AS (
		SELECT
			PLAYER_NAME,
			UNNEST(SEASON_STATS)::SEASON_STATS AS SEASON_STATS
		FROM
			PLAYERS
		WHERE
			PLAYER_NAME = 'Michael Jordan'
			AND CURRENT_SEASON = '2000'
	)
	--Because your players table stores multiple snapshots, if you UNNEST() without 
	--filtering, you will repeatedly explode the same historical arrays from every snapshot.
SELECT
	PLAYER_NAME,
	(SEASON_STATS::SEASON_STATS).*
FROM
	CTE
	----------------------------------------------------------------------------------------------------------
	--Scoring Class Table : Basically defining the type of player based on his points
	--Keeping Track of gap between current season and last played
CREATE TYPE SCORING_CLASS AS ENUM('star', 'good', 'average', 'bad')
DROP TABLE PLAYERS

CREATE TABLE PLAYERS (
	PLAYER_NAME TEXT,
	HEIGHT TEXT,
	COLLEGE TEXT,
	COUNTRY TEXT,
	DRAFT_YEAR TEXT,
	DRAFT_NUMBER TEXT,
	SEASON_STATS SEASON_STATS[],
	SCORING_CLASS SCORING_CLASS,
	YEARS_SINCE_LAST_PLAYED INTEGER,
	CURRENT_SEASON INTEGER
)



INSERT INTO
	PLAYERS (
		PLAYER_NAME,
		HEIGHT,
		COLLEGE,
		COUNTRY,
		DRAFT_YEAR,
		DRAFT_NUMBER,
		SEASON_STATS,
		SCORING_CLASS,
		YEARS_SINCE_LAST_PLAYED,
		CURRENT_SEASON
	)
WITH
	YESTERDAY AS (
		SELECT
			*
		FROM
			PLAYERS
		WHERE
			CURRENT_SEASON = 199
	),
	TODAY AS (
		SELECT
			*
		FROM
			PLAYER_SEASONS
		WHERE
			SEASON = 1998
	)
SELECT
	COALESCE(T.PLAYER_NAME, Y.PLAYER_NAME) AS PLAYER_NAME,
	COALESCE(T.HEIGHT, Y.HEIGHT) AS HEIGHT,
	COALESCE(T.COLLEGE, Y.COLLEGE) AS COLLEGE,
	COALESCE(T.COUNTRY, Y.COUNTRY) AS COUNTRY,
	COALESCE(T.DRAFT_YEAR, Y.DRAFT_YEAR) AS DRAFT_YEAR,
	COALESCE(T.DRAFT_NUMBER, Y.DRAFT_NUMBER) AS DRAFT_NUMBER,
	CASE
		WHEN Y.CURRENT_SEASON IS NULL THEN ARRAY[
			ROW (T.SEASON, T.GP, T.PTS, T.REB, T.AST)::SEASON_STATS
		]
		WHEN T.SEASON IS NOT NULL THEN Y.SEASON_STATS || ARRAY[
			ROW (T.SEASON, T.GP, T.PTS, T.REB, T.AST)::SEASON_STATS
		]
		ELSE Y.SEASON_STATS
	END AS SEASON_STATS,
	CASE
		WHEN T.SEASON IS NOT NULL THEN (
			CASE
				WHEN T.PTS > 20 THEN 'star'
				WHEN T.PTS > 15 THEN 'good'
				WHEN T.PTS > 10 THEN 'average'
				ELSE 'bad'
			END
		)::SCORING_CLASS
		ELSE Y.SCORING_CLASS
	END AS SCORING_CLASS,
	CASE
		WHEN T.SEASON IS NOT NULL THEN 0
		ELSE Y.YEARS_SINCE_LAST_PLAYED + 1
	END AS YEARS_SINCE_LAST_PLAYED,
	COALESCE(T.SEASON, Y.CURRENT_SEASON + 1) AS CURRENT_SEASON
FROM
	TODAY AS T
	FULL OUTER JOIN YESTERDAY AS Y ON Y.PLAYER_NAME = T.PLAYER_NAME

----------------------------------------------------------------------------------------------------------
-- Now we get all the last_played and what it's current rating is 
select * from players where current_season=1998

-----------------------------------------------------------------------------------------------
-- Analysis of the improvement of the star performance so comparing there first stats to the most recent one 
select player_name , SCORING_CLASS,
LATEST_SEASON / (
	CASE
		WHEN FIRST_SEASON = 0 THEN 1
		ELSE FIRST_SEASON
	END
) * 100 AS PERFORMANCE
FROM
	(
		SELECT
			PLAYER_NAME,
			SCORING_CLASS,
			(SEASON_STATS[1]::SEASON_STATS).PTS AS FIRST_SEASON,
			(SEASON_STATS[CARDINALITY(SEASON_STATS)]).PTS AS LATEST_SEASON
		FROM
			PLAYERS
		WHERE
			CURRENT_SEASON = 1998
	) S



