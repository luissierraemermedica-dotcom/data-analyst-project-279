/*
    OBJETIVO DE LA CONSULTA
    -----------------------
    Construye un reporte de rendimiento de campañas publicitarias,
    relacionando las sesiones/visitas de los usuarios con los leads
    generados y las compras realizadas.

    El resultado final combina:

    - Visitantes provenientes de determinados canales de adquisición.
    - Leads asociados a dichos visitantes.
    - Compras y revenue generados por los leads.
    - Costos diarios de publicidad provenientes de VK Ads y Yandex Ads.

    El resultado se agrupa por:
    - Fecha
    - UTM Source
    - UTM Medium
    - UTM Campaign

    Finalmente, se muestran los 15 registros con mayor revenue.
*/


/*
    CTE: visitor_with_lead
    ----------------------
    Relaciona las sesiones de los visitantes con los leads que
    posteriormente fueron creados por esos mismos visitantes.

    La condición:
        s.visit_date <= l.created_at

    garantiza que el lead se haya creado en la misma fecha/hora
    o después de la visita que se está relacionando.

    Se utiliza LEFT JOIN para conservar también las sesiones que
    no generaron ningún lead.
*/
WITH visitor_with_lead AS (

    SELECT

        -- Identificador único del visitante.
        -- Se utiliza posteriormente para contar visitantes.
        s.visitor_id,

        /*
            Fecha y hora de la visita.

            Se trunca la precisión a milisegundos para estandarizar
            el valor mostrado y posteriormente se convierte a texto
            con el formato:
                YYYY-MM-DD HH24:MI:SS.MS
        */
        to_char(
            date_trunc('milliseconds', s.visit_date),
            'YYYY-MM-DD HH24:MI:SS.MS'
        ) AS visit_date,

        -- Parámetros UTM utilizados para identificar
        -- la fuente, medio y campaña publicitaria.
        s.source   AS utm_source,
        s.medium   AS utm_medium,
        s.campaign AS utm_campaign,

        -- Información del lead asociado al visitante.
        l.lead_id,

        -- Fecha y hora de creación del lead.
        to_char(
            date_trunc('milliseconds', l.created_at),
            'YYYY-MM-DD HH24:MI:SS.MS'
        ) AS created_at,

        -- Valor monetario asociado al lead.
        l.amount,

        -- Motivo por el cual se cerró el lead,
        -- si aplica.
        l.closing_reason,

        -- Identificador del estado actual del lead.
        -- Se utiliza posteriormente para identificar las compras.
        l.status_id,

        /*
            Asigna un número de fila a cada registro del visitante.

            PARTITION BY visitor_id:
                Reinicia la numeración para cada visitante.

            ORDER BY visit_date DESC:
                La visita más reciente recibe RN = 1.

            Posteriormente, en sessions_agregate se utiliza:
                WHERE RN = 1

            para conservar únicamente la sesión más reciente
            de cada visitante.
        */
        ROW_NUMBER() OVER (
            PARTITION BY s.visitor_id
            ORDER BY s.visit_date DESC
        ) AS RN

    FROM sessions AS s

    /*
        Se utiliza LEFT JOIN para mantener las sesiones aunque
        el visitante no tenga un lead asociado.

        Un lead se considera relacionado con la sesión cuando:
        1. Pertenece al mismo visitante.
        2. El lead fue creado en la misma fecha/hora o después
           de la visita.
    */
    LEFT JOIN leads AS l
        ON s.visitor_id = l.visitor_id
        AND s.visit_date <= l.created_at

    /*
        Se consideran únicamente las sesiones provenientes
        de los medios publicitarios definidos en este reporte.

        Estos valores representan los canales de adquisición
        que se desean incluir en el análisis.
    */
    WHERE s.medium IN (
        'cpc',
        'cpm',
        'cpa',
        'youtube',
        'cpp',
        'tg',
        'social'
    )
),


/*
    CTE: sessions_agregate
    ----------------------
    Resume la información obtenida en visitor_with_lead
    a nivel de:

        Fecha + UTM Source + UTM Medium + UTM Campaign

    También calcula los principales indicadores de conversión:
        - Cantidad de visitantes.
        - Cantidad de leads.
        - Cantidad de compras.
        - Revenue generado.
*/
sessions_agregate AS (

    SELECT

        -- Se utiliza únicamente la fecha, ignorando la hora.
        DATE(visit_date) AS visit_date,

        -- Dimensiones de atribución de la campaña.
        utm_source,
        utm_medium,
        utm_campaign,

        /*
            Cantidad de visitantes.

            Como previamente se conserva únicamente RN = 1
            por visitante, COUNT(visitor_id) representa la cantidad
            de visitantes considerados para cada combinación de fecha
            y parámetros UTM.
        */
        COUNT(visitor_id) AS visitors_count,

        /*
            Cantidad de leads asociados.

            COUNT(lead_id) no cuenta los valores NULL, por lo que
            las sesiones sin lead no incrementan este contador.
        */
        COUNT(lead_id) AS leads_count,

        /*
            Cantidad de compras.

            Únicamente se contabilizan los leads cuyo status_id
            corresponde al estado 142.

            IMPORTANTE:
            El significado de status_id = 142 depende de la
            configuración de la aplicación/base de datos.
        */
        COUNT(lead_id) FILTER (
            WHERE status_id = 142
        ) AS purchases_count,

        /*
            Revenue generado por las compras.

            Solo se suman los importes de los leads cuyo estado
            corresponde a una compra (status_id = 142).
        */
        SUM(amount) FILTER (
            WHERE status_id = 142
        ) AS revenue

    FROM visitor_with_lead

    /*
        RN = 1 representa la visita más reciente de cada visitante.

        Esto evita contar varias sesiones del mismo visitante
        dentro del agregado final.
    */
    WHERE RN = 1

    GROUP BY
        1,  -- visit_date
        2,  -- utm_source
        3,  -- utm_medium
        4   -- utm_campaign
),


/*
    CTE: all_ads
    ------------
    Unifica los costos publicitarios de las diferentes plataformas
    en una sola estructura.

    UNION ALL conserva todos los registros de ambas tablas.

    Actualmente se incluyen:
        - VK Ads
        - Yandex Ads

    Ambas tablas deben tener una estructura compatible:
        campaign_date
        utm_source
        utm_medium
        utm_campaign
        daily_spent
*/
all_ads AS (

    SELECT
        campaign_date,
        utm_source,
        utm_medium,
        utm_campaign,
        daily_spent
    FROM vk_ads

    UNION ALL

    SELECT
        campaign_date,
        utm_source,
        utm_medium,
        utm_campaign,
        daily_spent
    FROM ya_ads
),


/*
    CTE: t_cost
    -----------
    Consolida el gasto publicitario.

    Se agrupa por la misma combinación de dimensiones utilizada
    para analizar las sesiones:

        Fecha + UTM Source + UTM Medium + UTM Campaign

    Esto permite posteriormente relacionar el gasto con los
    visitantes, leads, compras y revenue.
*/
t_cost AS (

    SELECT

        -- Se renombra campaign_date como visit_date
        -- para utilizar el mismo nombre de dimensión
        -- que en sessions_agregate.
        campaign_date AS visit_date,

        utm_source,
        utm_medium,
        utm_campaign,

        /*
            Suma el gasto de todas las fuentes publicitarias
            que coincidan en la misma fecha y combinación UTM.
        */
        SUM(daily_spent) AS total_cost

    FROM all_ads

    GROUP BY
        1,  -- visit_date
        2,  -- utm_source
        3,  -- utm_medium
        4   -- utm_campaign
)


/*
    CONSULTA FINAL
    --------------
    Combina las métricas de adquisición/conversión con
    el costo publicitario correspondiente.

    La tabla principal es sessions_agregate, por lo que se
    mantienen las combinaciones de campañas que generaron
    visitantes, aunque no tengan un registro de gasto asociado.
*/
SELECT

    -- Fecha del tráfico.
    sa.visit_date,

    -- Cantidad de visitantes.
    sa.visitors_count,

    -- Dimensiones de atribución de la campaña.
    sa.utm_source,
    sa.utm_medium,
    sa.utm_campaign,

    -- Gasto publicitario asociado a la campaña.
    tc.total_cost,

    -- Cantidad de leads generados.
    sa.leads_count,

    -- Cantidad de compras realizadas.
    sa.purchases_count,

    -- Revenue generado por las compras.
    sa.revenue

FROM sessions_agregate AS sa

/*
    LEFT JOIN:
    Mantiene todas las combinaciones de sesiones/campañas,
    incluso cuando no existe un costo publicitario registrado
    para esa combinación.
*/
LEFT JOIN t_cost AS tc

    /*
        El costo se relaciona utilizando exactamente las mismas
        dimensiones de atribución:
            - Fecha
            - Source
            - Medium
            - Campaign
    */
    ON tc.visit_date = sa.visit_date
    AND tc.utm_source = sa.utm_source
    AND tc.utm_medium = sa.utm_medium
    AND tc.utm_campaign = sa.utm_campaign


/*
    ORDEN DEL RESULTADO
    -------------------
    1. Revenue de mayor a menor.
       Las campañas sin revenue quedan al final.

    2. Fecha ascendente.

    3. Cantidad de visitantes de mayor a menor.

    4. Dimensiones UTM en orden alfabético.
*/
ORDER BY
    sa.revenue DESC NULLS LAST,
    sa.visit_date,
    sa.visitors_count DESC,
    sa.utm_source,
    sa.utm_medium,
    sa.utm_campaign


/*
    Se limita el resultado a los 15 registros
    que cumplen con el ordenamiento anterior.
*/
LIMIT 15;