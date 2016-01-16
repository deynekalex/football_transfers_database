--Cascade <=> Automatically drop objects that depend on the table (such as views).
DROP FUNCTION check_contract_after() CASCADE;
DROP FUNCTION check_contract_before() CASCADE;
--DROP TRIGGER check_new_contract_after ON contract;
--DROP TRIGGER check_new_contract_before ON contract;
DROP TABLE IF EXISTS championship CASCADE;
DROP TABLE IF EXISTS team CASCADE;
DROP TABLE IF EXISTS player CASCADE;
DROP TABLE IF EXISTS contract CASCADE;
DROP TABLE IF EXISTS citizenship CASCADE;
DROP TABLE IF EXISTS player_citizenship CASCADE;
DROP TYPE football_positions;

--create types
CREATE TYPE football_positions AS ENUM ('GK', 'SW', 'CB', 'LB', 'RB', 'LWB', 'RWB', 'DM', 'CM', 'AM', 'LW', 'RW', 'WF', 'CF', 'SS');
/*DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'football_positions') THEN
CREATE TYPE football_positions AS ENUM('GK','SW','CB','LB','RB','LWB','RWB','DM','CM','AM','LW','RW','WF');
    END IF;
END$$;*/

--create tables
CREATE TABLE championship (
  chId              SERIAL,
  cNAME             VARCHAR(100) NOT NULL,
  pre_season_starts DATE         NOT NULL,
  pre_season_ends   DATE         NOT NULL,
  mid_season_starts DATE         NOT NULL,
  mid_season_ends   DATE         NOT NULL,
  CHECK ((pre_season_ends - pre_season_starts) <= 96),
  CHECK ((mid_season_ends - mid_season_starts) <= 32),
  CONSTRAINT championship_pk PRIMARY KEY (chId)
);

CREATE TABLE team (
  tId             SERIAL,
  tName           VARCHAR(100) NOT NULL,
  transfer_budget INT          NOT NULL ,
  chId            INT,

  CHECK (transfer_budget >= 0),
  CONSTRAINT team_pk PRIMARY KEY (tid),
  FOREIGN KEY (chId) REFERENCES championship (chId) ON UPDATE CASCADE ON DELETE SET NULL
  --Если нац. чеспионат удаляется, то устанавливаем его NULL, что означает, что клуб пока не зарегестрирован
  -- ни в каком чеспионате
);

CREATE TABLE player (
  pId           SERIAL,
  pName         VARCHAR(100)       NOT NULL,
  date_of_birth DATE               NOT NULL,
  position      football_positions NOT NULL,
  tId           INT,
  est_price     INT                NOT NULL,
  --id команды, которой он принадлежит(не аренда!!!)

  CHECK (est_price >= 0),
  CHECK (date_of_birth <= current_date),
  CHECK (est_price >= 0),
  CONSTRAINT player_pk PRIMARY KEY (pId),
  FOREIGN KEY (tid) REFERENCES team (tId) ON UPDATE CASCADE ON DELETE SET NULL
  -- Если клуб удаляется, то устанавливаем NULL, что означает отсутствие клуба у игрока
);

CREATE TABLE citizenship (
  ciId   SERIAL,
  ciName VARCHAR(50) NOT NULL,
  CONSTRAINT citizenship_pk PRIMARY KEY (ciId)
);


CREATE TABLE player_citizenship (
  pId  INT NOT NULL,
  ciId INT NOT NULL,

  CONSTRAINT player_citizenship_pk PRIMARY KEY (pid, ciId),
  FOREIGN KEY (pId) REFERENCES player (pId) ON UPDATE CASCADE ON DELETE CASCADE,
  FOREIGN KEY (ciId) REFERENCES citizenship (ciId) ON UPDATE CASCADE ON DELETE CASCADE
  --если игрок или гражданство перестало существовать, то и не храним запись
);

CREATE TABLE contract (
  coId   SERIAL,
  fromId INT,
  toId   INT     NOT NULL,
  pId    INT     NOT NULL,
  salary INT     NOT NULL,
  signed DATE    NOT NULL,
  ended  DATE    NOT NULL,
  price  INT,
  isLoan BOOLEAN NOT NULL,

  CHECK (price >= 0),
  CHECK (salary >= 0),
  CONSTRAINT contract_pk PRIMARY KEY (coId),
  FOREIGN KEY (fromId) REFERENCES team (tId) ON UPDATE CASCADE ON DELETE NO ACTION,
  FOREIGN KEY (toId) REFERENCES team (tId) ON UPDATE CASCADE ON DELETE NO ACTION,
  FOREIGN KEY (pId) REFERENCES player (pId) ON UPDATE CASCADE ON DELETE NO ACTION
  --если клубы или игрок удаляется, то контракт все равно сохраняется.
);

--indexes
--на внешние ключи
CREATE INDEX team_championship ON team USING HASH (chId);

CREATE INDEX player_team ON player USING HASH (tid);

CREATE INDEX contract_player ON contract USING HASH (pId);

CREATE INDEX contract_toid ON contract USING HASH (toId);

CREATE INDEX contract_fromid ON contract USING HASH (fromId);
--на частые селекции
CREATE INDEX player_est_price ON player (est_price);

CREATE INDEX player_position ON player (position);

CREATE INDEX player_date_of_birth ON player (date_of_birth);

CREATE INDEX player_name ON player USING HASH (pName);

CREATE INDEX contract_ended ON contract (ended);

--triggers

/*CREATE OR REPLACE FUNCTION check_zero_price() RETURNS TRIGGER AS
$BODY$
DECLARE
  fromTeamId SERIAL;
BEGIN
    if (new.fromId = NULL) then
       if (new.price = 0) then
        return new;
      else
          RAISE EXCEPTION 'why price if not 0 euros? Player is free agent';
        END if;
    else
        return new;
    end if;
END
$BODY$ LANGUAGE 'plpgsql';

CREATE TRIGGER check_zero_price BEFORE INSERT ON contract FOR EACH ROW EXECUTE PROCEDURE check_zero_price();*/

select * FROM player;

CREATE OR REPLACE FUNCTION mmdd(DATE)
  RETURNS INT LANGUAGE SQL IMMUTABLE AS
$func$
SELECT ((extract('month' FROM $1) :: INT * 100) + extract('day' FROM $1) :: INT)
$func$;


CREATE OR REPLACE FUNCTION check_contract_before()
  RETURNS TRIGGER AS
$BODY$
DECLARE
  current_player_name          VARCHAR(100);
  current_player_date_of_birth DATE;
  current_team                 INT;
  current_team_name            VARCHAR(100);
  current_budget               INT;
  to_championship              INT;
  to_championship_name         VARCHAR(100);
  pre_starts                   DATE;
  pre_ends                     DATE;
  mid_starts                   DATE;
  mid_ends                     DATE;
BEGIN
  IF (new.fromId != current_team AND NOT current_team ISNULL)
  THEN
    RAISE EXCEPTION 'fromId is not equal to current tid of player.';
  END IF;

  SELECT pName
  INTO current_player_name
  FROM player
  WHERE pId = new.pId;
  IF (new.fromId ISNULL AND new.price != 0)
  THEN
    RAISE EXCEPTION 'Player %, is free agent. Price should be 0 euros. There is no team to pay', current_player_name;
  END IF;

  SELECT chId
  INTO to_championship
  FROM team
  WHERE tid = new.toId;
  SELECT cName
  INTO to_championship_name
  FROM championship
  WHERE chId = to_championship;
  SELECT
    pre_season_starts,
    pre_season_ends,
    mid_season_starts,
    mid_season_ends
  INTO pre_starts, pre_ends, mid_starts, mid_ends
  FROM championship
  WHERE chId = to_championship;
  IF ((mmdd(new.signed) NOT BETWEEN mmdd(pre_starts) AND mmdd(pre_ends)) AND
      (mmdd(new.signed) NOT BETWEEN mmdd(mid_starts) AND mmdd(mid_ends)))
  THEN
    RAISE EXCEPTION 'transfer window in % championship is closed.', to_championship;
  END IF;

  SELECT tid
  INTO current_team
  FROM player
  WHERE pId = new.pId;
  SELECT tName
  INTO current_team_name
  FROM team
  WHERE tid = current_team;
  SELECT transfer_budget
  INTO current_budget
  FROM team
  WHERE tId = current_team;
  IF (new.price > current_budget)
  THEN
    RAISE EXCEPTION 'There is no money in % team, transfer budget = %, price of % is %',
    current_team_name, current_budget, current_player_name, new.price;
  END IF;

  SELECT date_of_birth
  INTO current_player_date_of_birth
  FROM player
  WHERE pId = new.pId;
  IF (new.signed - current_player_date_of_birth < 365 * 14)
  THEN
    RAISE EXCEPTION 'footballer % is too young to have a professional contract', current_player_name;
  END IF;


  RETURN new;
END
$BODY$ LANGUAGE 'plpgsql';

CREATE TRIGGER check_new_contract_before BEFORE INSERT OR UPDATE ON contract
FOR EACH ROW
EXECUTE PROCEDURE check_contract_before();

CREATE OR REPLACE FUNCTION check_contract_after()
  RETURNS TRIGGER AS
$BODY$
DECLARE
BEGIN
  IF (new.isLoan = FALSE)
  THEN
    UPDATE player
    SET tId = new.toId
    WHERE pId = new.pId;
    UPDATE team
    SET transfer_budget = transfer_budget - new.price
    WHERE tId = new.toId;
  END IF;
  RETURN new;
END
$BODY$ LANGUAGE 'plpgsql';

CREATE TRIGGER check_new_contract_after AFTER INSERT OR UPDATE ON contract
FOR EACH ROW
EXECUTE PROCEDURE check_contract_after();


/*CREATE OR REPLACE FUNCTION check_contract_end()
  RETURNS INT AS
$BODY$
BEGIN
  UPDATE player
  SET tId = NULL
  WHERE tId IN (SELECT tId
                FROM contract
                WHERE ended > current_date
                ORDER BY ended DESC);
END;
$BODY$ LANGUAGE 'plpgsql';*/

--insert data
COPY championship FROM '/home/deynekalex/Desktop/databases/footballtransfers/championship.csv' DELIMITER ',' CSV;

COPY team FROM '/home/deynekalex/Desktop/databases/footballtransfers/team.csv' DELIMITER ',' CSV;

COPY player FROM '/home/deynekalex/Desktop/databases/footballtransfers/player.csv' DELIMITER ',' CSV;

COPY citizenship FROM '/home/deynekalex/Desktop/databases/footballtransfers/citizenship.csv' DELIMITER ',' CSV;

COPY contract FROM '/home/deynekalex/Desktop/databases/footballtransfers/contract.csv' DELIMITER ',' CSV;

COPY player_citizenship FROM '/home/deynekalex/Desktop/databases/footballtransfers/player_citizenship.csv' DELIMITER ',' CSV;


SELECT *
FROM championship
ORDER BY cNAME;
SELECT *
FROM team
ORDER BY tName;
SELECT *
FROM player
ORDER BY est_price DESC;
SELECT *
FROM citizenship
ORDER BY ciName;
SELECT *
FROM contract
ORDER BY signed;
--select queries

--имя футболиста с его гражданством
SELECT
  pName,
  ciName
FROM player
  NATURAL JOIN player_citizenship
  NATURAL JOIN citizenship
ORDER BY pName;

--имена футболистов имеющих более одного гражданства
SELECT pName
FROM player
WHERE pId IN (SELECT pId
              FROM player_citizenship
              GROUP BY pId
              HAVING count(*) > 1);

--свободные агенты
SELECT *
FROM player
WHERE tid ISNULL;

--игроки, чьи контракты закончаться раньше чем через 2 года
SELECT *
FROM player
WHERE pid IN (SELECT pId
              FROM contract
              WHERE ended - current_date < 2 * 365 AND contract.isLoan = FALSE
              ORDER BY ended DESC);

--views
CREATE VIEW average_salary AS
  SELECT
    toid,
    avg(salary) AS avg
  FROM contract
  GROUP BY toId
  ORDER BY avg, toId DESC;

SELECT *
FROM average_salary;

--средние зарплаты по национальным чемпионатам
SELECT
  cNAME,
  avg(average_salary.avg)
FROM average_salary
  INNER JOIN team ON average_salary.toId = team.tId
  INNER JOIN championship ON team.chId = championship.chId
GROUP BY cNAME;

--такие пары игроков и команд, такие, команда может купить игрока
SELECT
  pName,
  tName
FROM team
  CROSS JOIN player
WHERE transfer_budget >= player.est_price;

--игроки из бразилии, чьи зарплаты выше средней по игрокам
SELECT
  pName,
  ciName,
  est_price
FROM player_citizenship
  LEFT JOIN citizenship ON player_citizenship.ciId = citizenship.ciId
  LEFT JOIN player ON player_citizenship.pId = player.pId
WHERE ciName = 'Brazil' AND est_price > ANY
                            (SELECT avg(est_price)
                             FROM player);

--Непротиворечивость содержимого БД
--Может быть описана набором правил и проверена
