WITH std_md_pass AS (
    /* 학생별, MD별, 과목별 이수 학점 + 마지막 학기 */
    SELECT
        ms.MD_CD,
        p.STD_NO,
        p.SBJT_CD,
        MAX(TO_CHAR(p."YEAR") || LPAD(TRIM(TO_CHAR(p.SMESTR)),2,'0')) AS LAST_SEM_KEY,
        MAX(sub.SBJT_CREDIT) AS SBJT_CREDIT
    FROM V_MD_SUBJECT ms
     JOIN V_STD_CDP_PASSCURI p ON ms.SBJT_CD = p.SBJT_CD
     JOIN V_STD_CDP_SUBJECT sub ON p.SBJT_KEY_CD = sub.SBJT_KEY_CD
    WHERE p.MD_YN = 'Y'
                AND p.PASS_POINT IS NOT NULL AND p.PASS_POINT NOT IN ('F')
                AND ms.MD_CD = 'G9'
                AND TO_CHAR(p."YEAR") <= '2026'
                AND TRIM(TO_CHAR(p.SMESTR)) IN ('1', '1.5', '2', '2.5')
            GROUP BY ms.MD_CD, p.STD_NO, p.SBJT_CD
        ),
        /* 학생별, MD별 총 이수학점 + 마지막 학기 */
        std_md_credit AS (
            SELECT
                MD_CD,
                STD_NO,
            SUM(SBJT_CREDIT) AS TOTAL_CREDIT,
            MAX(LAST_SEM_KEY) AS LAST_SEM_KEY
            FROM std_md_pass
            GROUP BY MD_CD, STD_NO
        ),
        /* MD별 참여학생 수 (이수 + 수강중) */
        participant_stats AS (
            SELECT
                MD_CD,
                COUNT(*) AS PART_CNT
            FROM (
                SELECT DISTINCT ms.MD_CD, p.STD_NO
                FROM V_MD_SUBJECT ms
                JOIN V_STD_CDP_PASSCURI p ON ms.SBJT_CD = p.SBJT_CD
                    AND p.MD_YN = 'Y'
                        AND TO_CHAR(p."YEAR") <= '2026'
                        AND TRIM(TO_CHAR(p.SMESTR)) IN ('1', '1.5', '2', '2.5')
                UNION

                SELECT DISTINCT ms.MD_CD, sg.STD_NO
                FROM V_MD_SUBJECT ms
                JOIN V_STD_CDP_SUGANGCURI sg ON ms.SBJT_CD = sg.SBJT_CD
                        AND TO_CHAR(sg."YEAR") <= '2026'
                        AND TRIM(TO_CHAR(sg.SMESTR)) IN ('1', '1.5', '2', '2.5')
                JOIN V_STD_CDP_SUBJECT sub ON sg.SBJT_KEY_CD = sub.SBJT_KEY_CD
                    AND sub.MD_YN = 'Y'
            )
            GROUP BY MD_CD
        ),
        /* MD별 평균 진도율 (PASSCURI 이수자 기준) */
        progress_stats AS (
            SELECT
                MD_CD,
                ROUND(AVG(LEAST(TOTAL_CREDIT * 100.0 / 12, 100))) AS AVG_PROGRESS
            FROM std_md_credit
            GROUP BY MD_CD
        ),
        /* MD별 이수완료 학생 수 (학점 합 >= 12) */
        complete_stats AS (
            SELECT
                MD_CD,
                COUNT(*) AS COMPLETE_CNT
            FROM std_md_credit
            WHERE TOTAL_CREDIT >= 12
            GROUP BY MD_CD
        ),
        /* 학기별 이수완료 평균인원 */
        semester_avg AS (
            SELECT
                MD_CD,
                ROUND(AVG(SEM_CNT)) AS AVG_SEM_COMPLETE
            FROM (
                SELECT
                    MD_CD,
                    LAST_SEM_KEY,
                    COUNT(*) AS SEM_CNT
                FROM std_md_credit
                WHERE TOTAL_CREDIT >= 12
                GROUP BY MD_CD, LAST_SEM_KEY
            )
            GROUP BY MD_CD
        )

SELECT
    TT.MD_CD,
    TT.MD_NM,
    TT.MD_DIV_NM,
    '12학점' AS REQ_CREDIT_COUNT,
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
                      NVL(ps.PART_CNT,0) AS TOTAL_PARTICIPANT, -- 참여 학생 수
                      NVL(cs.COMPLETE_CNT,0) AS TOTAL_COMPLETED, -- 이수완료 총 학생 수
                      NVL(pr.AVG_PROGRESS,0) || '%' AS AVG_PROGRESS_RATE, -- 평균 진도율
                      NVL(sa.AVG_SEM_COMPLETE,0) AS AVG_SEM_COMPLETE -- 학기별 이수완료 평균인원
                  FROM V_MD_COURSE mc
                           LEFT JOIN participant_stats ps ON mc.MD_CD = ps.MD_CD
                           LEFT JOIN progress_stats pr ON mc.MD_CD = pr.MD_CD
                           LEFT JOIN complete_stats cs ON mc.MD_CD = cs.MD_CD
                           LEFT JOIN semester_avg sa ON mc.MD_CD = sa.MD_CD
                  WHERE
                      mc.USE_YN = 'Y'
                            AND mc.MD_CD = 'G9'
                ) TEMP
            ) TT