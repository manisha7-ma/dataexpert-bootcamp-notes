-- =====================================================================================================
-- PLAYER TABLE CREATION
-- =====================================================================================================

-- The original PLAYER_SEASONS table contains one row per player per season.
-- In this lab we are creating a cumulative player table that stores:
--
-- 1. Historical season stats as an ARRAY of STRUCTS
-- 2. Current scoring classification of the player
-- 3. Whether the player is currently active
-- 4. Number of years since the player last played
--
-- This table acts like a yearly snapshot table where each row represents:
--
-- "What did we know about this player at this season?"
--
-- NOTE:
-- The previous lab version did not contain the ISACTIVE column.

-- Player season dataset range:
-- MIN YEAR = 1996
-- MAX YEAR = 2022


DROP TABLE PLAYERS;

CREATE TABLE PLAYERS (
	PLAYER_NAME TEXT,
	HEIGHT TEXT,
	COLLEGE TEXT,
	COUNTRY TEXT,
	DRAFT_YEAR TEXT,
	DRAFT_NUMBER TEXT,

	-- Array of season level statistics stored cumulatively
	SEASON_STATS SEASON_STATS[],

	-- Current scoring quality bucket of the player
	SCORING_CLASS SCORING_CLASS,

	-- Tracks inactivity duration
	-- 0  -> currently active
	-- 1+ -> years since last active season
	YEARS_SINCE_LAST_PLAYED INTEGER,

	-- Snapshot season for this row
	CURRENT_SEASON INTEGER,

	-- Indicates whether player played in CURRENT_SEASON
	ISACTIVE BOOLEAN,

	PRIMARY KEY (PLAYER_NAME, CURRENT_SEASON)
);

-- =====================================================================================================
-- INCREMENTAL YEAR-BY-YEAR SNAPSHOT BUILDING
-- =====================================================================================================

-- We incrementally build the PLAYERS table year by year.
--
-- Every iteration:
--
-- yesterday = previous season snapshot
-- today     = current raw season data
--
-- Then we merge them together.
--
-- Why FULL OUTER JOIN?
--
-- Because we need to handle ALL scenarios:
--
-- 1. Existing active players
-- 2. Retired/inactive players
-- 3. Brand new players
--
-- This is essentially a snapshot propagation pipeline.


DO $$
DECLARE
    yr INTEGER;
BEGIN

FOR yr IN 1996..2022 LOOP

    INSERT INTO PLAYERS (
        PLAYER_NAME,
        HEIGHT,
        COLLEGE,
        COUNTRY,
        DRAFT_YEAR,
        DRAFT_NUMBER,
        SEASON_STATS,
        SCORING_CLASS,
        YEARS_SINCE_LAST_PLAYED,
        CURRENT_SEASON,
        ISACTIVE
    )

    WITH yesterday AS (

        -- Previous season snapshot
        SELECT *
        FROM PLAYERS
        WHERE CURRENT_SEASON = yr - 1
    ),

    today AS (

        -- Current season raw data
        SELECT *
        FROM PLAYER_SEASONS
        WHERE SEASON = yr
    )

    SELECT

        -- COALESCE handles:
        -- active players
        -- retired players
        -- new players

        COALESCE(T.PLAYER_NAME, Y.PLAYER_NAME),

        COALESCE(T.HEIGHT, Y.HEIGHT),

        COALESCE(T.COLLEGE, Y.COLLEGE),

        COALESCE(T.COUNTRY, Y.COUNTRY),

        COALESCE(T.DRAFT_YEAR, Y.DRAFT_YEAR),

        COALESCE(
            T.DRAFT_NUMBER,
            Y.DRAFT_NUMBER
        ),

        -- =============================================================================================
        -- SEASON_STATS LOGIC
        -- =============================================================================================

        CASE

            -- Brand new player
            -- Create first season stats array
            WHEN Y.CURRENT_SEASON IS NULL THEN
                ARRAY[
                    ROW(
                        T.SEASON,
                        T.GP,
                        T.PTS,
                        T.REB,
                        T.AST
                    )::SEASON_STATS
                ]

            -- Existing active player
            -- Append latest season stats to cumulative history
            WHEN T.SEASON IS NOT NULL THEN
                Y.SEASON_STATS || ARRAY[
                    ROW(
                        T.SEASON,
                        T.GP,
                        T.PTS,
                        T.REB,
                        T.AST
                    )::SEASON_STATS
                ]

            -- Retired/inactive player
            -- Keep previous cumulative stats unchanged
            ELSE
                Y.SEASON_STATS
        END,

        -- =============================================================================================
        -- SCORING CLASS LOGIC
        -- =============================================================================================

        -- Scoring class is recalculated ONLY if player played this season.
        --
        -- Otherwise we preserve previous scoring state.

        CASE
            WHEN T.SEASON IS NOT NULL THEN
                (
                    CASE
                        WHEN T.PTS > 20 THEN 'star'
                        WHEN T.PTS > 15 THEN 'good'
                        WHEN T.PTS > 10 THEN 'average'
                        ELSE 'bad'
                    END
                )::SCORING_CLASS

            ELSE
                Y.SCORING_CLASS
        END,

        -- =============================================================================================
        -- INACTIVITY TRACKING
        -- =============================================================================================

        -- If player played:
        -- years_since_last_played = 0
        --
        -- Otherwise:
        -- increment inactivity streak

        CASE
            WHEN T.SEASON IS NOT NULL THEN 0
            ELSE Y.YEARS_SINCE_LAST_PLAYED + 1
        END,

        -- =============================================================================================
        -- CURRENT SNAPSHOT YEAR
        -- =============================================================================================

        -- Active players:
        -- current season becomes current row season
        --
        -- Inactive players:
        -- increment previous snapshot year

        COALESCE(
            T.SEASON,
            Y.CURRENT_SEASON + 1
        ),

        -- =============================================================================================
        -- ACTIVE STATUS
        -- =============================================================================================

        -- If player exists in current season:
        -- active = TRUE
        --
        -- Otherwise:
        -- active = FALSE

        CASE
            WHEN T.SEASON IS NOT NULL THEN TRUE
            ELSE FALSE
        END

    FROM TODAY T
    FULL OUTER JOIN YESTERDAY Y
        ON Y.PLAYER_NAME = T.PLAYER_NAME;

END LOOP;

END $$;

-- =====================================================================================================
-- VIEWING FINAL SNAPSHOT
-- =====================================================================================================

-- Shows latest state of all players in 2022

SELECT
	PLAYER_NAME,
	SCORING_CLASS,
	ISACTIVE
FROM
	PLAYERS
WHERE
	CURRENT_SEASON = 2022
ORDER BY
	PLAYER_NAME;


-- =====================================================================================================
-- SLOWLY CHANGING DIMENSION (SCD TYPE 2)
-- =====================================================================================================

-- We are now building a Slowly Changing Dimension table.
--
-- Goal:
--
-- Track historical state transitions for:
--
-- 1. scoring_class
-- 2. is_active status
--
-- Instead of storing one row per season,
-- we store one row per continuous state period.
--
-- Example:
--
-- Michael Jordan:
--
-- average -> average -> average -> star -> star
--
-- becomes:
--
-- average : 1996 - 1998
-- star    : 1999 - 2000
--
-- This compresses repeated states efficiently.


CREATE TABLE PLAYERS_SCD (
	PLAYER_NAME TEXT,

	SCORING_CLASS SCORING_CLASS,

	ISACTIVE BOOLEAN,

	-- Period when this state became valid
	START_SEASON INTEGER,

	-- Period when this state stopped being valid
	END_SEASON INTEGER,

	-- Snapshot version
	CURRENT_SEASON INTEGER,

	PRIMARY KEY (PLAYER_NAME, START_SEASON)
);

-- DROP TABLE PLAYERS_SCD;


-- =====================================================================================================
-- BUILDING INITIAL SCD TABLE
-- =====================================================================================================

INSERT INTO
	PLAYERS_SCD (
		PLAYER_NAME,
		ISACTIVE,
		SCORING_CLASS,
		START_SEASON,
		END_SEASON,
		CURRENT_SEASON
	)

WITH

-- =============================================================================================
-- STEP 1:
-- Bring previous state using LAG()
-- =============================================================================================

WITH_PREVIOUS AS (

	SELECT
		PLAYER_NAME,
		SCORING_CLASS,
		ISACTIVE,
		CURRENT_SEASON,

		-- Previous scoring state
		LAG(SCORING_CLASS) OVER (
			PARTITION BY PLAYER_NAME
			ORDER BY CURRENT_SEASON
		) AS PREVIOUS_SCORING_CLASS,

		-- Previous active state
		LAG(ISACTIVE) OVER (
			PARTITION BY PLAYER_NAME
			ORDER BY CURRENT_SEASON
		) AS PREVIOUS_ISACTIVE

	FROM PLAYERS

	WHERE CURRENT_SEASON <= 2021
),

-- =============================================================================================
-- STEP 2:
-- Detect whether state changed
-- =============================================================================================

WITH_INDICATORS AS (

	SELECT
		*,

		CASE

			-- scoring class changed
			WHEN SCORING_CLASS <> PREVIOUS_SCORING_CLASS THEN 1

			-- active status changed
			WHEN ISACTIVE <> PREVIOUS_ISACTIVE THEN 1

			-- no state change
			ELSE 0

		END AS CHANGE_INDICATOR

	FROM WITH_PREVIOUS
),

-- =============================================================================================
-- STEP 3:
-- Build streak groups
-- =============================================================================================

-- We cumulatively sum the change indicators.
--
-- Every new change creates a new streak identifier.
--
-- Example:
--
-- values:     A A A B B C
-- indicators: 0 0 0 1 0 1
-- streaks:    0 0 0 1 1 2
--
-- This allows grouping continuous unchanged periods together.


WITH_STREAKS AS (

	SELECT
		*,

		SUM(CHANGE_INDICATOR) OVER (
			PARTITION BY PLAYER_NAME
			ORDER BY CURRENT_SEASON
		) AS STREAK_IDENTIFIER

	FROM WITH_INDICATORS
)

-- =============================================================================================
-- STEP 4:
-- Collapse streaks into SCD periods
-- =============================================================================================

SELECT
	PLAYER_NAME,

	ISACTIVE,

	SCORING_CLASS,

	MIN(CURRENT_SEASON) AS START_SEASON,

	MAX(CURRENT_SEASON) AS END_SEASON,

	2021 AS CURRENT_SEASON

FROM WITH_STREAKS

GROUP BY
	PLAYER_NAME,
	STREAK_IDENTIFIER,
	ISACTIVE,
	SCORING_CLASS

ORDER BY
	PLAYER_NAME,
	STREAK_IDENTIFIER;



-- =====================================================================================================
-- INCREMENTAL SCD UPDATE LOGIC
-- =====================================================================================================

-- Instead of rebuilding the entire SCD table every year,
-- we incrementally process only the latest season.
--
-- This is how production warehouse pipelines typically work.


-- =============================================================================================
-- CUSTOM STRUCT TYPE
-- =============================================================================================

-- Used to temporarily hold old + new state rows together
-- before UNNESTING them into separate records.

CREATE TYPE SCD_TYPE AS (
	SCORING_CLASS SCORING_CLASS,
	ISACTIVE BOOLEAN,
	START_SEASON INTEGER,
	END_SEASON INTEGER
);


WITH

-- =============================================================================================
-- ACTIVE SCD RECORDS FROM LAST SNAPSHOT
-- =============================================================================================

LAST_SEASON_SCD AS (

	SELECT *

	FROM PLAYERS_SCD

	WHERE CURRENT_SEASON = 2021
	AND END_SEASON = 2021
),

-- =============================================================================================
-- FULLY HISTORICAL RECORDS
-- =============================================================================================

-- These rows are already closed historically.
-- No changes needed.

HISTORICAL_SCD AS (

	SELECT *

	FROM PLAYERS_SCD

	WHERE CURRENT_SEASON = 2021
	AND END_SEASON < 2021
),

-- =============================================================================================
-- CURRENT SEASON PLAYER DATA
-- =============================================================================================

THIS_SEASON_DATA AS (

	SELECT *

	FROM PLAYERS

	WHERE CURRENT_SEASON = 2022
),

-- =============================================================================================
-- UNCHANGED RECORDS
-- =============================================================================================

-- If scoring class + active state remain same:
--
-- simply extend END_SEASON

UNCHANGED_RECORDS AS (

	SELECT
		TS.PLAYER_NAME,

		TS.SCORING_CLASS,

		TS.ISACTIVE,

		LS.START_SEASON,

		TS.CURRENT_SEASON AS END_SEASON

	FROM THIS_SEASON_DATA TS

	JOIN LAST_SEASON_SCD LS
		ON LS.PLAYER_NAME = TS.PLAYER_NAME

	AND TS.SCORING_CLASS = LS.SCORING_CLASS

	AND TS.ISACTIVE = LS.ISACTIVE
),

-- =============================================================================================
-- CHANGED RECORDS
-- =============================================================================================

-- Whenever state changes:
--
-- we create TWO rows:
--
-- 1. old closed historical row
-- 2. new active row

CHANGED_RECORDS AS (

	SELECT
		TS.PLAYER_NAME,

		UNNEST(
			ARRAY[

				-- previous historical row
				ROW (
					LS.SCORING_CLASS,
					LS.ISACTIVE,
					LS.START_SEASON,
					LS.END_SEASON
				)::SCD_TYPE,

				-- new active row
				ROW (
					TS.SCORING_CLASS,
					TS.ISACTIVE,
					TS.CURRENT_SEASON,
					TS.CURRENT_SEASON
				)::SCD_TYPE
			]
		) AS RECORDS

	FROM THIS_SEASON_DATA TS

	JOIN LAST_SEASON_SCD LS
		ON LS.PLAYER_NAME = TS.PLAYER_NAME

	AND (
		TS.SCORING_CLASS <> LS.SCORING_CLASS
		OR TS.ISACTIVE <> LS.ISACTIVE
	)
),

-- =============================================================================================
-- EXTRACT STRUCT FIELDS
-- =============================================================================================

UNNESTED_CHANGED_RECORDS AS (

	SELECT
		PLAYER_NAME,

		(RECORDS::SCD_TYPE).SCORING_CLASS,

		(RECORDS::SCD_TYPE).ISACTIVE,

		(RECORDS::SCD_TYPE).START_SEASON,

		(RECORDS::SCD_TYPE).END_SEASON

	FROM CHANGED_RECORDS
),

-- =============================================================================================
-- BRAND NEW PLAYERS
-- =============================================================================================

NEW_RECORDS AS (

	SELECT
		TS.PLAYER_NAME,

		TS.SCORING_CLASS,

		TS.ISACTIVE,

		TS.CURRENT_SEASON,

		TS.CURRENT_SEASON

	FROM THIS_SEASON_DATA TS

	LEFT JOIN LAST_SEASON_SCD LS
		ON LS.PLAYER_NAME = TS.PLAYER_NAME

	WHERE LS.PLAYER_NAME IS NULL
)

-- =============================================================================================
-- FINAL UNION
-- =============================================================================================

-- Combine all categories of records to create the latest SCD snapshot:
--
-- 1. HISTORICAL_SCD
--    Rows that were already historically closed before this season.
--    These records remain unchanged permanently.
--
-- 2. UNNESTED_CHANGED_RECORDS
--    Players whose state changed this season.
--    This produces:
--      - one closed historical row
--      - one newly opened active row
--
-- 3. NEW_RECORDS
--    Completely new players appearing for the first time.
--
-- 4. UNCHANGED_RECORDS
--    Players whose scoring class and active status remained unchanged.
--    Only their END_SEASON gets extended.

SELECT
	*,

	2022 AS CURRENT_SEASON

FROM (

	-- Previously closed historical rows
	SELECT * 
	FROM HISTORICAL_SCD

	UNION ALL

	-- Changed player states
	SELECT * 
	FROM UNNESTED_CHANGED_RECORDS

	UNION ALL

	-- Brand new players
	SELECT * 
	FROM NEW_RECORDS

	UNION ALL

	-- Players with unchanged states
	SELECT * 
	FROM UNCHANGED_RECORDS

) s;
