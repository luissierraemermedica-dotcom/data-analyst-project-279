/*
    Objetivo:
    Obtener, para cada visitante, la sesión de tráfico pagado/marketing
    más reciente que ocurrió antes de la creación de un lead.
*/

WITH visitor_with_lead AS (

    SELECT
        -- Identificador único del visitante
        l.visitor_id,

        /*
            Formateamos la fecha de visita para que siempre
            tenga exactamente 3 dígitos de milisegundos.
        */
        to_char(
            date_trunc('milliseconds', s.visit_date),
            'YYYY-MM-DD HH24:MI:SS.MS'
        ) AS visit_date,

        -- Parámetros UTM de la sesión
        s.source   AS utm_source,
        s.medium   AS utm_medium,
        s.campaign AS utm_campaign,

        -- Información asociada al lead
        l.lead_id,

        /*
            Formateamos la fecha de creación del lead
            con exactamente 3 dígitos de milisegundos.
        */
        to_char(
            date_trunc('milliseconds', l.created_at),
            'YYYY-MM-DD HH24:MI:SS.MS'
        ) AS created_at,

        l.amount,
        l.closing_reason,
        l.status_id,

        /*
            La sesión más reciente de cada visitante
            recibe RN = 1.
        */
        ROW_NUMBER() OVER (
            PARTITION BY s.visitor_id
            ORDER BY s.visit_date DESC
        ) AS RN

    FROM sessions s

    LEFT JOIN leads l
        ON s.visitor_id = l.visitor_id
        AND s.visit_date <= l.created_at

    WHERE s.medium IN (
        'cpc',
        'cpm',
        'cpa',
        'youtube',
        'cpp',
        'tg',
        'social'
    )
)

SELECT
    visitor_id,
    visit_date,
    utm_source,
    utm_medium,
    utm_campaign,
    lead_id,
    created_at,
    amount,
    closing_reason,
    status_id

FROM visitor_with_lead

WHERE RN = 1

ORDER BY
    8 DESC NULLS LAST,
    2 ASC,
    3,
    4,
    5

LIMIT 10;
