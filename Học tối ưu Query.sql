-- selectMdDataQuery
WITH ms_sbjt AS (
        SELECT ms.SBJT_CD, ms.MD_CD
        FROM V_MD_SUBJECT ms
        WHERE ms.MD_CD = :md
    )

   , passcuri_all AS (
        SELECT /*+ MATERIALIZE */
            STD_NO,
            SBJT_CD,
            SBJT_KEY_CD,
            "YEAR",
            SMESTR,
            PASS_POINT
        FROM V_STD_CDP_PASSCURI
        WHERE MD_YN = 'Y'
          AND SBJT_CD IN (SELECT SBJT_CD FROM ms_sbjt)
    )

   , passcuri_filtered AS (
        SELECT /*+ MATERIALIZE */
            STD_NO,
            SBJT_CD,
            SBJT_KEY_CD,
            MAX("YEAR") AS "YEAR",
            MAX(SMESTR) AS SMESTR
        FROM passcuri_all
        WHERE PASS_POINT IS NOT NULL
          AND PASS_POINT <> 'F' -- NOT IN ('F',...)
        GROUP BY STD_NO, SBJT_KEY_CD, SBJT_CD
    )

   , sem_key_map AS (
        SELECT /*+ MATERIALIZE */
            RPAD('1',   3) AS SMESTR_RAW, '01'   AS SEM_SUFFIX FROM DUAL UNION ALL
        SELECT RPAD('2',   3),            '02'                 FROM DUAL UNION ALL
        SELECT RPAD('1.5', 3),            '01.5'               FROM DUAL UNION ALL
        SELECT RPAD('2.5', 3),            '02.5'               FROM DUAL
    )

   , sem_values AS (
        SELECT /*+ MATERIALIZE */
            RPAD(TRIM(t.COLUMN_VALUE), 3) AS SMESTR_RAW
        FROM (
                 SELECT /*+ CARDINALITY(c 4) */ COLUMN_VALUE
                 FROM TABLE(SYS.ODCIVARCHAR2LIST(:semester)) c
             ) t
    )

   , max_sem_key AS (
        SELECT /*+ MATERIALIZE */
            MAX(:p_year || skm.SEM_SUFFIX) AS MAX_KEY
        FROM sem_values sv
        JOIN sem_key_map skm ON sv.SMESTR_RAW = skm.SMESTR_RAW
    )

   , std_md_pass AS (
        SELECT
            ms.MD_CD,
            pf.STD_NO,
            pf.SBJT_CD,
            MAX(pf."YEAR" || skm.SEM_SUFFIX) AS LAST_SEM_KEY,
            MAX(sub.SBJT_CREDIT)             AS SBJT_CREDIT
        FROM ms_sbjt ms
                 JOIN passcuri_filtered pf  ON ms.SBJT_CD = pf.SBJT_CD
                 JOIN V_STD_CDP_SUBJECT sub ON pf.SBJT_KEY_CD = sub.SBJT_KEY_CD
                 JOIN sem_key_map skm       ON RPAD(pf.SMESTR, 3) = skm.SMESTR_RAW
        GROUP BY ms.MD_CD, pf.STD_NO, pf.SBJT_CD
    )

   , std_md_credit AS (
        SELECT /*+ MATERIALIZE */
            MD_CD,
            STD_NO,
            SUM(SBJT_CREDIT)  AS TOTAL_CREDIT,
            MAX(LAST_SEM_KEY) AS LAST_SEM_KEY
        FROM std_md_pass
        WHERE LAST_SEM_KEY <= (SELECT MAX_KEY FROM max_sem_key)
        GROUP BY MD_CD, STD_NO
    )

   , participant_stats AS (
    SELECT /*+ MATERIALIZE */ MD_CD, COUNT(DISTINCT STD_NO) AS PART_CNT
    FROM (
             SELECT ms.MD_CD, p.STD_NO
             FROM ms_sbjt ms
                      JOIN passcuri_all p  ON ms.SBJT_CD = p.SBJT_CD
                      JOIN sem_key_map skm ON RPAD(TRIM(p.SMESTR), 3) = skm.SMESTR_RAW
             WHERE (p."YEAR" || skm.SEM_SUFFIX) <= (SELECT MAX_KEY FROM max_sem_key)

             UNION ALL

             SELECT ms.MD_CD, sg.STD_NO
             FROM ms_sbjt ms
                      JOIN V_STD_CDP_SUGANGCURI sg ON ms.SBJT_CD = sg.SBJT_CD
                      JOIN V_STD_CDP_SUBJECT sub   ON sg.SBJT_KEY_CD = sub.SBJT_KEY_CD
                 AND sub.MD_YN = 'Y'
                      JOIN sem_key_map skm         ON RPAD(TRIM(sg.SMESTR), 3) = skm.SMESTR_RAW
             WHERE (sg."YEAR" || skm.SEM_SUFFIX) <= (SELECT MAX_KEY FROM max_sem_key)
         )
    GROUP BY MD_CD
)

   , progress_stats AS (
        /* Calculate avg progress rate of all students in each MD */
        SELECT
            MD_CD,
            ROUND(AVG(LEAST(TOTAL_CREDIT * 100.0 / 12, 100))) AS AVG_PROGRESS
        FROM std_md_credit
        GROUP BY MD_CD
    )

   , complete_stats AS (
        /* Count the number of students completed MD (achieved 12 credits). */
        SELECT
            MD_CD,
            COUNT(*) AS COMPLETE_CNT
        FROM std_md_credit
        WHERE TOTAL_CREDIT   >=   12
        GROUP BY MD_CD
    )

   , semester_avg AS (
    SELECT
        MD_CD,
        ROUND(AVG(SEM_CNT)) AS AVG_SEM_COMPLETE
    FROM (
             SELECT
                 MD_CD,
                 LAST_SEM_KEY,
                 COUNT(*) AS SEM_CNT
             FROM std_md_credit
             WHERE TOTAL_CREDIT   >=   12
             GROUP BY MD_CD, LAST_SEM_KEY
         )
    GROUP BY MD_CD
)

SELECT
    TT.MD_CD,
    TT.MD_NM,
    TT.MD_DIV_NM,
    '12??' AS REQ_CREDIT_COUNT,
    TT.TOTAL_PARTICIPANT,
    TT.TOTAL_COMPLETED,
    TT.AVG_PROGRESS_RATE,
    TT.AVG_SEM_COMPLETE
FROM (
         SELECT
             COUNT(*) OVER() AS TOTAL_COUNT,
             TEMP.*,
             ROW_NUMBER() OVER(ORDER BY TEMP.MD_NM DESC) AS RNUM
         FROM (
                  SELECT
                      mc.MD_CD,
                      mc.MD_NM,
                      mc.MD_DIV_NM,
                      NVL(ps.PART_CNT,0) AS TOTAL_PARTICIPANT,
                      NVL(cs.COMPLETE_CNT,0) AS TOTAL_COMPLETED,
                      NVL(pr.AVG_PROGRESS,0) || '%' AS AVG_PROGRESS_RATE,
                      NVL(sa.AVG_SEM_COMPLETE,0) AS AVG_SEM_COMPLETE
                  FROM V_MD_COURSE mc
                           LEFT JOIN participant_stats ps ON mc.MD_CD = ps.MD_CD
                           LEFT JOIN progress_stats pr ON mc.MD_CD = pr.MD_CD
                           LEFT JOIN complete_stats cs ON mc.MD_CD = cs.MD_CD
                           LEFT JOIN semester_avg sa ON mc.MD_CD = sa.MD_CD
                  WHERE
                      mc.USE_YN = 'Y'
                    AND mc.MD_CD = :md
              ) TEMP
     ) TT;

-- selectMdDataBySemesterQuery
WITH ms_sbjt AS (
    SELECT ms.SBJT_CD, ms.MD_CD
    FROM V_MD_SUBJECT ms
    WHERE ms.MD_CD = :md
)

   , passcuri_all AS (
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        "YEAR", SMESTR, PASS_POINT
    FROM V_STD_CDP_PASSCURI
    WHERE MD_YN = 'Y'
      AND SBJT_CD IN (SELECT SBJT_CD FROM ms_sbjt)
)

   , passcuri_filtered AS (
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        MAX("YEAR") AS "YEAR",
        MAX(SMESTR) AS SMESTR
    FROM passcuri_all
    WHERE PASS_POINT IS NOT NULL
      AND PASS_POINT <> 'F'
    GROUP BY STD_NO, SBJT_KEY_CD, SBJT_CD
)

   , sem_key_map AS (
    SELECT /*+ MATERIALIZE */
        RPAD('1',   3) AS SMESTR_RAW, '01'   AS SEM_SUFFIX, '1'   AS SMESTR_CD, '1??' AS SMESTR_NM, 1 AS SORT FROM DUAL UNION ALL
    SELECT RPAD('2',   3),            '02',                 '2',                 '2??',              3          FROM DUAL UNION ALL
    SELECT RPAD('1.5', 3),            '01.5',               '1.5',               '????',             2          FROM DUAL UNION ALL
    SELECT RPAD('2.5', 3),            '02.5',               '2.5',               '????',             4          FROM DUAL
)

   , sem_input AS (
    SELECT /*+ MATERIALIZE */
        RPAD(TRIM(t.COLUMN_VALUE), 3) AS SMESTR_RAW
    FROM (
             SELECT /*+ CARDINALITY(c 4) */ COLUMN_VALUE
             FROM TABLE(SYS.ODCIVARCHAR2LIST(:semester)) c
         ) t
)

   , max_sem_key AS (
    SELECT /*+ MATERIALIZE */
        MAX(:year || skm.SEM_SUFFIX) AS MAX_KEY
    FROM sem_input s
             JOIN sem_key_map skm ON s.SMESTR_RAW = skm.SMESTR_RAW
)

   , year_sem_list AS (
    SELECT /*+ MATERIALIZE */
        :year                   AS "YEAR",
        skm.SMESTR_CD,
        skm.SMESTR_NM,
        skm.SORT,
        :year || skm.SEM_SUFFIX AS SEM_KEY
    FROM sem_input s
             JOIN sem_key_map skm ON s.SMESTR_RAW = skm.SMESTR_RAW
)

   , std_md_pass AS (
    SELECT
        ms.MD_CD, pf.STD_NO, pf.SBJT_CD,
        MAX(pf."YEAR" || skm.SEM_SUFFIX) AS LAST_SEM_KEY,
        MAX(sub.SBJT_CREDIT)             AS SBJT_CREDIT
    FROM ms_sbjt ms
             JOIN passcuri_filtered pf  ON ms.SBJT_CD         = pf.SBJT_CD
             JOIN V_STD_CDP_SUBJECT sub ON pf.SBJT_KEY_CD     = sub.SBJT_KEY_CD
             JOIN sem_key_map skm       ON RPAD(pf.SMESTR, 3) = skm.SMESTR_RAW
    GROUP BY ms.MD_CD, pf.STD_NO, pf.SBJT_CD
)

   , std_md_credit AS (
    SELECT /*+ MATERIALIZE */
        MD_CD, STD_NO,
        SUM(SBJT_CREDIT)  AS TOTAL_CREDIT,
        MAX(LAST_SEM_KEY) AS LAST_SEM_KEY
    FROM std_md_pass
    WHERE LAST_SEM_KEY <= (SELECT MAX_KEY FROM max_sem_key)
    GROUP BY MD_CD, STD_NO
)

   , std_sem_all AS (
    /* ✅ Materialize union passcuri + sugangcuri 1 lần
       thay vì bị drive bởi NESTED LOOPS 4 lần */
    SELECT /*+ MATERIALIZE */
        p.STD_NO,
        p."YEAR" || skm.SEM_SUFFIX AS SEM_KEY
    FROM ms_sbjt ms
             JOIN passcuri_all p  ON ms.SBJT_CD = p.SBJT_CD
             JOIN sem_key_map skm ON RPAD(p.SMESTR, 3) = skm.SMESTR_RAW

    UNION ALL

    SELECT sg.STD_NO,
           sg."YEAR" || skm.SEM_SUFFIX AS SEM_KEY
    FROM ms_sbjt ms
             JOIN V_STD_CDP_SUGANGCURI sg ON ms.SBJT_CD = sg.SBJT_CD
             JOIN V_STD_CDP_SUBJECT sub   ON sg.SBJT_KEY_CD = sub.SBJT_KEY_CD
        AND sub.MD_YN = 'Y'
             JOIN sem_key_map skm         ON RPAD(sg.SMESTR, 3) = skm.SMESTR_RAW
)

   , part_by_sem AS (
    SELECT
        ys.SEM_KEY, ys."YEAR", ys.SMESTR_CD, ys.SMESTR_NM, ys.SORT,
        COUNT(DISTINCT std.STD_NO) AS PART_CNT
    FROM year_sem_list ys
    LEFT JOIN std_sem_all std ON std.SEM_KEY <= ys.SEM_KEY
    GROUP BY ys.SEM_KEY, ys."YEAR", ys.SMESTR_CD, ys.SMESTR_NM, ys.SORT
)

   , complete_by_sem AS (
    SELECT
        ys.SEM_KEY,
        COUNT(DISTINCT smc.STD_NO) AS COMPLETE_CNT
    FROM year_sem_list ys
             LEFT JOIN std_md_credit smc ON smc.LAST_SEM_KEY <= ys.SEM_KEY
        AND smc.TOTAL_CREDIT  >= 12
    GROUP BY ys.SEM_KEY
)

SELECT
    p."YEAR"                  AS YEAR_COMP,
    p.SMESTR_CD,
    p.SMESTR_NM,
    NVL(p.PART_CNT, 0)        AS CNT_STD_APP,
    NVL(c.COMPLETE_CNT, 0)    AS CNT_STD_COMPLETE,
    CASE
        WHEN NVL(p.PART_CNT, 0) = 0 THEN '0%'
        ELSE ROUND(NVL(c.COMPLETE_CNT, 0) * 100.0 / p.PART_CNT, 1) || '%'
        END                       AS PERCENT_COMPLETE
FROM part_by_sem p
         LEFT JOIN complete_by_sem c ON p.SEM_KEY = c.SEM_KEY
ORDER BY p."YEAR" DESC, p.SORT;

-- selectMdCompleteByPercentQuery
WITH ms_sbjt AS (
    SELECT ms.SBJT_CD, ms.MD_CD
    FROM V_MD_SUBJECT ms
    WHERE 1=1
      AND ms.MD_CD = :md
)

   , passcuri_all AS (
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        "YEAR", SMESTR, PASS_POINT
    FROM V_STD_CDP_PASSCURI
    WHERE MD_YN = 'Y'
      AND SBJT_CD IN (SELECT SBJT_CD FROM ms_sbjt)
)

   , passcuri_filtered AS (
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        MAX("YEAR") AS "YEAR",
        MAX(SMESTR) AS SMESTR
    FROM passcuri_all
    WHERE PASS_POINT IS NOT NULL
      AND PASS_POINT <> 'F'
    GROUP BY STD_NO, SBJT_KEY_CD, SBJT_CD
)

   , sem_key_map AS (
    SELECT /*+ MATERIALIZE */
        RPAD('1',   3) AS SMESTR_RAW, '01'   AS SEM_SUFFIX, '1'   AS SMESTR_CD, '1??' AS SMESTR_NM, 1 AS SORT FROM DUAL UNION ALL
    SELECT RPAD('2',   3),            '02',                 '2',                 '2??',              3          FROM DUAL UNION ALL
    SELECT RPAD('1.5', 3),            '01.5',               '1.5',               '????',             2          FROM DUAL UNION ALL
    SELECT RPAD('2.5', 3),            '02.5',               '2.5',               '????',             4          FROM DUAL
)

   , sem_input AS (
    SELECT /*+ MATERIALIZE */
        RPAD(TRIM(t.COLUMN_VALUE), 3) AS SMESTR_RAW
    FROM (
             SELECT /*+ CARDINALITY(c 4) */ COLUMN_VALUE
             FROM TABLE(SYS.ODCIVARCHAR2LIST(:semester)) c
         ) t
)

   , max_sem_key AS (
    SELECT /*+ MATERIALIZE */
        MAX(:year || skm.SEM_SUFFIX) AS MAX_KEY
    FROM sem_input s
             JOIN sem_key_map skm ON s.SMESTR_RAW = skm.SMESTR_RAW
)

   , std_md_pass AS (
    SELECT
        ms.MD_CD,
        pf.STD_NO,
        pf.SBJT_CD,
        MAX(pf."YEAR" || skm.SEM_SUFFIX) AS LAST_SEM_KEY,
        MAX(sub.SBJT_CREDIT)             AS SBJT_CREDIT
    FROM ms_sbjt ms
     JOIN passcuri_filtered pf  ON ms.SBJT_CD         = pf.SBJT_CD
     JOIN V_STD_CDP_SUBJECT sub ON pf.SBJT_KEY_CD     = sub.SBJT_KEY_CD
     JOIN sem_key_map skm       ON RPAD(pf.SMESTR, 3) = skm.SMESTR_RAW
    GROUP BY ms.MD_CD, pf.STD_NO, pf.SBJT_CD
)

   , std_md_credit AS (
    SELECT /*+ MATERIALIZE */
        MD_CD, STD_NO,
        SUM(SBJT_CREDIT)  AS TOTAL_CREDIT,
        MAX(LAST_SEM_KEY) AS LAST_SEM_KEY
    FROM std_md_pass
    WHERE LAST_SEM_KEY  <=  (SELECT MAX_KEY FROM max_sem_key)
    GROUP BY MD_CD, STD_NO
)

   , participant_stats AS (
    SELECT DISTINCT STD_NO, MD_CD
    FROM (
             SELECT ms.MD_CD, p.STD_NO
             FROM V_MD_SUBJECT ms
              JOIN passcuri_all p ON ms.SBJT_CD = p.SBJT_CD
              JOIN sem_key_map skm ON RPAD(p.SMESTR, 3) = skm.SMESTR_RAW
             WHERE (p."YEAR" || skm.SEM_SUFFIX)  <=  (SELECT MAX_KEY FROM max_sem_key)
               AND ms.MD_CD = :md

             UNION ALL

             SELECT ms.MD_CD, sg.STD_NO
             FROM V_MD_SUBJECT ms
             JOIN V_STD_CDP_SUGANGCURI sg ON ms.SBJT_CD = sg.SBJT_CD
             JOIN V_STD_CDP_SUBJECT sub ON sg.SBJT_KEY_CD = sub.SBJT_KEY_CD
                 AND sub.MD_YN = 'Y'
             JOIN sem_key_map skm ON RPAD(sg.SMESTR, 3) = skm.SMESTR_RAW
             WHERE (sg."YEAR" || skm.SEM_SUFFIX)  <=  (SELECT MAX_KEY FROM max_sem_key)
               AND ms.MD_CD = :md
         )
)

   , student_progress AS (
    SELECT
        p.STD_NO,
        p.MD_CD,
        LEAST(NVL(c.TOTAL_CREDIT, 0) * 100.0 / 12, 100) AS PROGRESS_PERCENT
    FROM participant_stats p
             LEFT JOIN std_md_credit c ON p.STD_NO = c.STD_NO
        AND p.MD_CD  = c.MD_CD
)

SELECT
    COUNT(CASE WHEN PROGRESS_PERCENT    BETWEEN 0  AND 25  THEN 1 END) AS RANGE1,
    COUNT(CASE WHEN PROGRESS_PERCENT   >     25  AND PROGRESS_PERCENT  <=   50  THEN 1 END) AS RANGE2,
    COUNT(CASE WHEN PROGRESS_PERCENT   >     50  AND PROGRESS_PERCENT  <=   75  THEN 1 END) AS RANGE3,
    COUNT(CASE WHEN PROGRESS_PERCENT   >     75  AND PROGRESS_PERCENT  <    100 THEN 1 END) AS RANGE4,
    COUNT(CASE WHEN PROGRESS_PERCENT   >=    100 THEN 1 END) AS RANGE5
FROM student_progress;

-- selectMdCompleteListQuery
WITH ms_sbjt AS (
    SELECT ms.SBJT_CD, ms.MD_CD
    FROM V_MD_SUBJECT ms
    WHERE ms.MD_CD = :md
)

   , passcuri_all AS (
    /* ✅ Tách riêng — scan PASSCURI 1 lần duy nhất */
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        "YEAR", SMESTR, PASS_POINT
    FROM V_STD_CDP_PASSCURI
    WHERE MD_YN = 'Y'
      AND SBJT_CD IN (SELECT SBJT_CD FROM ms_sbjt)
)

   , passcuri_filtered AS (
    /* ✅ Đọc từ passcuri_all — không scan lại bảng lớn */
    SELECT /*+ MATERIALIZE */
        STD_NO, SBJT_CD, SBJT_KEY_CD,
        MAX("YEAR") AS "YEAR",
        MAX(SMESTR) AS SMESTR
    FROM passcuri_all
    WHERE PASS_POINT IS NOT NULL
      AND PASS_POINT <> 'F'
    GROUP BY STD_NO, SBJT_KEY_CD, SBJT_CD
)

   , sem_key_map AS (
    /* ✅ Thêm MATERIALIZE */
    SELECT /*+ MATERIALIZE */
        RPAD('1',   3) AS SMESTR_RAW, '01'   AS SEM_SUFFIX, '1??' AS SMESTR_NM FROM DUAL UNION ALL
    SELECT RPAD('2',   3),            '02',                 '2??'              FROM DUAL UNION ALL
    SELECT RPAD('1.5', 3),            '01.5',               '????'            FROM DUAL UNION ALL
    SELECT RPAD('2.5', 3),            '02.5',               '????'            FROM DUAL
)

   , sem_input AS (
    /* ✅ Materialize collection + CARDINALITY hint → estimate đúng 4 rows */
    SELECT /*+ MATERIALIZE */
        RPAD(TRIM(t.COLUMN_VALUE), 3) AS SMESTR_RAW
    FROM (
             SELECT /*+ CARDINALITY(c 4) */ COLUMN_VALUE
             FROM TABLE(SYS.ODCIVARCHAR2LIST(:semesters)) c
         ) t
)

   , max_sem_key AS (
    SELECT /*+ MATERIALIZE */
        MAX(:year || skm.SEM_SUFFIX) AS MAX_KEY
    FROM sem_input s
             JOIN sem_key_map skm ON s.SMESTR_RAW = skm.SMESTR_RAW
)

   , std_md_pass AS (
    SELECT
        ms.MD_CD, pf.STD_NO, pf.SBJT_CD,
        MAX(pf."YEAR" || skm.SEM_SUFFIX) AS LAST_SEM_KEY,
        MAX(sub.SBJT_CREDIT)             AS SBJT_CREDIT
    FROM ms_sbjt ms
             JOIN passcuri_filtered pf  ON ms.SBJT_CD         = pf.SBJT_CD
             JOIN V_STD_CDP_SUBJECT sub ON pf.SBJT_KEY_CD     = sub.SBJT_KEY_CD
             JOIN sem_key_map skm       ON RPAD(pf.SMESTR, 3) = skm.SMESTR_RAW
    GROUP BY ms.MD_CD, pf.STD_NO, pf.SBJT_CD
)

   , std_md_credit AS (
    /* ✅ Thêm MATERIALIZE */
    SELECT /*+ MATERIALIZE */
        MD_CD, STD_NO,
        SUM(SBJT_CREDIT)  AS TOTAL_CREDIT,
        MAX(LAST_SEM_KEY) AS LAST_SEM_KEY
    FROM std_md_pass
    WHERE LAST_SEM_KEY <= (SELECT MAX_KEY FROM max_sem_key)
    GROUP BY MD_CD, STD_NO
)

   , completed_students AS (
    SELECT
        cs.MD_CD, cs.STD_NO,
        cs.TOTAL_CREDIT,
        cs.LAST_SEM_KEY,
        SUBSTR(cs.LAST_SEM_KEY, 1, 4)  AS LAST_YEAR,
        skm.SMESTR_NM                  AS LAST_SMESTR_NM
    FROM std_md_credit cs
             JOIN sem_key_map skm ON SUBSTR(cs.LAST_SEM_KEY, 5) = skm.SEM_SUFFIX
    WHERE cs.TOTAL_CREDIT >= 12
    -- ✅ Bỏ: AND LAST_SEM_KEY <= max_sem_key — thừa, đã filter trong std_md_credit
)

SELECT
    TT.TOTAL_COUNT,
    TT.RNO,
    TT.RNUM,
    TT.MD_CD,
    TT.STD_NO,
    TT.STD_NM,
    TT.MJ_CD_NM,
    TT.LAST_YEAR     AS "YEAR",
    TT.LAST_SMESTR_NM AS SMESTR,
    TT.TOTAL_CREDIT,
    TT.CERT_NO,
    TT.STATUS_CERT,
    TT.ISSUE_DT
FROM (
         SELECT
             COUNT(*) OVER()                                                          AS TOTAL_COUNT,
             ROW_NUMBER() OVER(ORDER BY TEMP.LAST_SEM_KEY DESC, TEMP.STD_NO ASC)    AS RNUM,
             -- ✅ Bỏ window function thứ 3, tính RNO từ TOTAL_COUNT - RNUM + 1
             COUNT(*) OVER() - ROW_NUMBER() OVER(ORDER BY TEMP.LAST_SEM_KEY DESC, TEMP.STD_NO ASC) + 1 AS RNO,
             TEMP.*
         FROM (
                  SELECT
                      cs.MD_CD,
                      cs.STD_NO,
                      vstd.KOR_NM                           AS STD_NM,
                      vstd.MJ_CD_NM,
                      cs.LAST_YEAR,
                      cs.LAST_SMESTR_NM,
                      cs.TOTAL_CREDIT,
                      cs.LAST_SEM_KEY,
                      cert.CERT_NO,
                      CASE
                          WHEN cert.CERT_NO IS NOT NULL THEN '????'
                          ELSE '-'
                          END                                   AS STATUS_CERT,
                      TO_CHAR(cert.ISSUE_DT, 'YYYY-MM-DD') AS ISSUE_DT
                  FROM completed_students cs
                           JOIN V_STD_CDP_SREG vstd ON vstd.STD_NO = cs.STD_NO
                           LEFT JOIN V_MD_CERT cert ON cert.STD_NO = cs.STD_NO
                      AND cert.MD_CD  = cs.MD_CD
              ) TEMP
     ) TT
-- ✅ Dùng bind variable thay hardcode '0' và '15'
ORDER BY TT.RNUM ASC