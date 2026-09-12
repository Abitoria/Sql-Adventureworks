/*
   AdventureWorks - Business Analysis Queries
   Author: Olawoyin Olufunmilayo Esther
   Database: AdventureWorks (OLTP schema), SQL Server

   
   - SANITY CHECK
    confirm the size and shape of the data before
   analysing it, and check whether ship dates vary at all.
*/

SELECT
    (SELECT COUNT(*) FROM Sales.SalesOrderHeader)                  AS OrderCount,
    (SELECT COUNT(*) FROM Sales.SalesOrderDetail)                  AS OrderLineCount,
    (SELECT COUNT(*) FROM Sales.Customer)                          AS CustomerCount,
    (SELECT MIN(OrderDate) FROM Sales.SalesOrderHeader)            AS FirstOrder,
    (SELECT MAX(OrderDate) FROM Sales.SalesOrderHeader)            AS LastOrder,
    (SELECT COUNT(DISTINCT DATEDIFF(DAY, OrderDate, ShipDate))
       FROM Sales.SalesOrderHeader WHERE ShipDate IS NOT NULL)     AS DistinctShipLags;


/* 
    - REVENUE RANKING vs GROSS PROFIT RANKING
   Question: which product subcategories earn the most gross
   profit, and does that ranking differ from the revenue ranking?

   the biggest seller is often not the biggest
   earner. The RankGap column is the finding - a large positive
   gap means a subcategory sells well but earns comparatively
   little.



   StandardCost is the product's CURRENT cost, not its cost on the date of sale.
   Production.ProductCostHistory holds the historical costs
   .
    */
WITH SubcategoryPerformance AS (
    SELECT
        pc.Name                                                   AS Category,
        ps.Name                                                   AS Subcategory,
        SUM(sod.LineTotal)                                        AS Revenue,
        SUM(p.StandardCost * sod.OrderQty)                        AS EstimatedCost,
        SUM(sod.LineTotal - (p.StandardCost * sod.OrderQty))      AS GrossProfit,
        SUM(sod.OrderQty)                                         AS UnitsSold
    FROM Sales.SalesOrderDetail       AS sod
    JOIN Production.Product           AS p  ON p.ProductID  = sod.ProductID
    JOIN Production.ProductSubcategory AS ps ON ps.ProductSubcategoryID = p.ProductSubcategoryID
    JOIN Production.ProductCategory   AS pc ON pc.ProductCategoryID = ps.ProductCategoryID
    GROUP BY pc.Name, ps.Name
)
SELECT
    Category,
    Subcategory,
    CAST(Revenue     AS DECIMAL(18,2))                            AS Revenue,
    CAST(GrossProfit AS DECIMAL(18,2))                            AS GrossProfit,
    CAST(100.0 * GrossProfit / NULLIF(Revenue, 0) AS DECIMAL(5,2)) AS MarginPct,
    UnitsSold,
    RANK() OVER (ORDER BY Revenue DESC)                           AS RevenueRank,
    RANK() OVER (ORDER BY GrossProfit DESC)                       AS ProfitRank,
    RANK() OVER (ORDER BY GrossProfit DESC)
      - RANK() OVER (ORDER BY Revenue DESC)                       AS RankGap
FROM SubcategoryPerformance
ORDER BY GrossProfit DESC;


/* 
    - WAS THE DISCOUNTING WORTH IT?
   Question: did discounted order lines sell enough extra volume
   to justify the margin given away?

  comparing AvgUnitsPerLine across the discount
   bands against MarginPct. If units barely rise as discounts
   deepen, the discounting is destroying margin without buying
   volume.
    */
SELECT
    CASE
        WHEN sod.UnitPriceDiscount = 0      THEN 'No discount'
        WHEN sod.UnitPriceDiscount <= 0.05  THEN '1 - 5 percent'
        WHEN sod.UnitPriceDiscount <= 0.15  THEN '6 - 15 percent'
        WHEN sod.UnitPriceDiscount <= 0.30  THEN '16 - 30 percent'
        ELSE 'Over 30 percent'
    END                                                           AS DiscountBand,
    COUNT(*)                                                      AS OrderLines,
    SUM(sod.OrderQty)                                             AS UnitsSold,
    CAST(AVG(CAST(sod.OrderQty AS DECIMAL(10,2))) AS DECIMAL(10,2)) AS AvgUnitsPerLine,
    CAST(SUM(sod.LineTotal) AS DECIMAL(18,2))                     AS Revenue,
    CAST(SUM(sod.LineTotal - (p.StandardCost * sod.OrderQty)) AS DECIMAL(18,2)) AS GrossProfit,
    CAST(100.0 * SUM(sod.LineTotal - (p.StandardCost * sod.OrderQty))
         / NULLIF(SUM(sod.LineTotal), 0) AS DECIMAL(5,2))         AS MarginPct
FROM Sales.SalesOrderDetail AS sod
JOIN Production.Product     AS p ON p.ProductID = sod.ProductID
GROUP BY
    CASE
        WHEN sod.UnitPriceDiscount = 0      THEN 'No discount'
        WHEN sod.UnitPriceDiscount <= 0.05  THEN '1 - 5 percent'
        WHEN sod.UnitPriceDiscount <= 0.15  THEN '6 - 15 percent'
        WHEN sod.UnitPriceDiscount <= 0.30  THEN '16 - 30 percent'
        ELSE 'Over 30 percent'
    END
ORDER BY Revenue DESC;

 /*-- CUSTOMER CONCENTRATION
   Question: how much of the revenue comes from the top slice of
   customers, and how many customers ordered only once?

   */
WITH CustomerRevenue AS (
    SELECT
        soh.CustomerID,
        SUM(soh.TotalDue)  AS Revenue,
        COUNT(*)           AS OrderCount
    FROM Sales.SalesOrderHeader AS soh
    GROUP BY soh.CustomerID
),
Deciles AS (
    SELECT
        CustomerID,
        Revenue,
        NTILE(10) OVER (ORDER BY Revenue DESC) AS RevenueDecile
    FROM CustomerRevenue
)
SELECT
    RevenueDecile,
    COUNT(*)                                                      AS Customers,
    CAST(SUM(Revenue) AS DECIMAL(18,2))                           AS Revenue,
    CAST(100.0 * SUM(Revenue) / SUM(SUM(Revenue)) OVER ()
         AS DECIMAL(5,2))                                         AS RevenueSharePct
FROM Deciles
GROUP BY RevenueDecile
ORDER BY RevenueDecile;

-- repeat versus one-time buyers
WITH CustomerOrders AS (
    SELECT CustomerID, COUNT(*) AS OrderCount, SUM(TotalDue) AS Revenue
    FROM Sales.SalesOrderHeader
    GROUP BY CustomerID
)
SELECT
    CASE WHEN OrderCount = 1 THEN 'One-time buyer' ELSE 'Repeat buyer' END AS BuyerType,
    COUNT(*)                                                      AS Customers,
    CAST(SUM(Revenue) AS DECIMAL(18,2))                           AS Revenue,
    CAST(AVG(Revenue) AS DECIMAL(18,2))                           AS AvgRevenuePerCustomer
FROM CustomerOrders
GROUP BY CASE WHEN OrderCount = 1 THEN 'One-time buyer' ELSE 'Repeat buyer' END;


/* 
   - ORDER FULFILMENT TIMING
   Question: how long do orders take to ship, and does that vary
   by territory?

   ONLY RUN THIS if Query 0 showed DistinctShipLags greater than 1.
   Otherwise the ship dates are a fixed offset.
   */
SELECT
    st.Name                                                       AS Territory,
    st.CountryRegionCode                                          AS CountryCode,
    COUNT(*)                                                      AS Orders,
    CAST(AVG(CAST(DATEDIFF(DAY, soh.OrderDate, soh.ShipDate) AS DECIMAL(10,2)))
         AS DECIMAL(10,2))                                        AS AvgDaysToShip,
    MIN(DATEDIFF(DAY, soh.OrderDate, soh.ShipDate))               AS MinDaysToShip,
    MAX(DATEDIFF(DAY, soh.OrderDate, soh.ShipDate))               AS MaxDaysToShip,
    SUM(CASE WHEN soh.ShipDate > soh.DueDate THEN 1 ELSE 0 END)   AS LateOrders,
    CAST(100.0 * SUM(CASE WHEN soh.ShipDate > soh.DueDate THEN 1 ELSE 0 END)
         / COUNT(*) AS DECIMAL(5,2))                              AS LatePct
FROM Sales.SalesOrderHeader AS soh
JOIN Sales.SalesTerritory   AS st ON st.TerritoryID = soh.TerritoryID
WHERE soh.ShipDate IS NOT NULL
GROUP BY st.Name, st.CountryRegionCode
ORDER BY AvgDaysToShip DESC;


/* 
    VENDOR RELIABILITY
   Question: which vendors have the highest rejection rates on
   goods received?

    */
SELECT
    v.Name                                                        AS Vendor,
    v.CreditRating,
    COUNT(DISTINCT pod.PurchaseOrderID)                           AS PurchaseOrders,
    SUM(pod.OrderQty)                                             AS QtyOrdered,
    SUM(pod.ReceivedQty)                                          AS QtyReceived,
    SUM(pod.RejectedQty)                                          AS QtyRejected,
    CAST(100.0 * SUM(pod.RejectedQty) / NULLIF(SUM(pod.ReceivedQty), 0)
         AS DECIMAL(5,2))                                         AS RejectRatePct,
    CAST(SUM(pod.RejectedQty * pod.UnitPrice) AS DECIMAL(18,2))   AS ValueRejected
FROM Purchasing.PurchaseOrderDetail AS pod
JOIN Purchasing.PurchaseOrderHeader AS poh ON poh.PurchaseOrderID = pod.PurchaseOrderID
JOIN Purchasing.Vendor              AS v   ON v.BusinessEntityID  = poh.VendorID
GROUP BY v.Name, v.CreditRating
HAVING SUM(pod.ReceivedQty) > 0
ORDER BY RejectRatePct DESC;


/* 
    SALES QUOTA ATTAINMENT
   Question: which sales people are hitting their targets?

   */
SELECT
    p.FirstName + ' ' + p.LastName                                AS SalesPerson,
    ISNULL(st.Name, 'No territory assigned')                      AS Territory,
    CAST(sp.SalesQuota AS DECIMAL(18,2))                          AS SalesQuota,
    CAST(sp.SalesYTD   AS DECIMAL(18,2))                          AS SalesYTD,
    CAST(100.0 * sp.SalesYTD / NULLIF(sp.SalesQuota, 0) AS DECIMAL(6,2)) AS AttainmentPct,
    CASE
        WHEN sp.SalesQuota IS NULL                THEN 'No quota set'
        WHEN sp.SalesYTD >= sp.SalesQuota         THEN 'At or above quota'
        ELSE 'Below quota'
    END                                                           AS Status
FROM Sales.SalesPerson    AS sp
JOIN Person.Person        AS p  ON p.BusinessEntityID = sp.BusinessEntityID
LEFT JOIN Sales.SalesTerritory AS st ON st.TerritoryID = sp.TerritoryID
ORDER BY AttainmentPct DESC;