SET XACT_ABORT ON
BEGIN TRAN AUDIT_TRANSACTION

DECLARE @SqlStatement VARCHAR(MAX), 
		@AuditSchema VARCHAR(20), 
		@TriggerLabel VARCHAR(20), 
		@TableSchema VARCHAR(100), 
		@TableName VARCHAR(100), 
		@Index int, 
		@Action varchar(20),
		@Label varchar(20),
		@Collection varchar(20)

SET @AuditSchema = 'audit' -- Schema in which audit logging tables will be created.
SET @TriggerLabel = '__audit_log_trigger' -- Descriptor for generated triggers, should be something unique so this script doesn't kill non-audit triggers.
	
SELECT [TABLE_SCHEMA], [TABLE_NAME] INTO #TempTables FROM INFORMATION_SCHEMA.TABLES 
		WHERE TABLE_SCHEMA IN ('dbo') -- Schemas from which audit logging tables will be created.
		AND TABLE_TYPE = 'BASE TABLE'
	  -- Define Table Filters Here
		AND TABLE_NAME NOT LIKE 'AspNet%'
		AND TABLE_NAME NOT LIKE '%__RefactorLog%'
		AND TABLE_NAME NOT LIKE '%__MigrationHistory%'
		AND TABLE_SCHEMA != @AuditSchema

-- Delete Existing Tables
PRINT ' -- Deleting all existing ' + QUOTENAME(@AuditSchema) + ' Tables --'
SET @SqlStatement = ''
SELECT @SqlStatement = @SqlStatement
	+ 'DROP TABLE ' + QUOTENAME(@AuditSchema) + '.' + QUOTENAME(TABLE_NAME) + CHAR(13)
	FROM INFORMATION_SCHEMA.TABLES
		WHERE TABLE_SCHEMA = @AuditSchema
-- PRINT @SqlStatement
EXEC (@SqlStatement)

-- Delete Triggers
SET @SqlStatement = ''
PRINT ' -- Deleting ' + QUOTENAME(@TriggerLabel) + ' Triggers -- '
SELECT @SqlStatement = @SqlStatement
	+ 'DROP TRIGGER ' +QUOTENAME(SMA.name) + '.' + QUOTENAME(TR.NAME) + CHAR(13)
		FROM SYS.TRIGGERS AS TR
			JOIN SYS.TABLES AS TBL
				ON TR.parent_id = TBL.object_id
			JOIN SYS.SCHEMAS AS SMA
				ON TBL.schema_id = SMA.schema_id
		WHERE [TR].[NAME] LIKE @TriggerLabel + '%'
-- PRINT @SqlStatement
EXEC (@SqlStatement)

-- Drop Existing Schema
IF EXISTS (SELECT * FROM SYS.SCHEMAS WHERE name = @AuditSchema)
BEGIN
	PRINT ' -- Dropping ' + QUOTENAME(@AuditSchema) + ' Schema --'
	SET @SqlStatement = 'DROP SCHEMA ' + QUOTENAME(@AuditSchema)
	-- PRINT @SqlStatement
	EXEC (@SqlStatement)
END

-- Create Schema
PRINT ' -- Creating ' + QUOTENAME(@AuditSchema) + ' Schema --'
SET @SqlStatement = 'CREATE SCHEMA ' + QUOTENAME(@AuditSchema)
-- PRINT @SqlStatement
EXEC (@SqlStatement)

-- Create Tables
PRINT ' -- ' + QUOTENAME(@AuditSchema) + ' Creating Tables -- '
SET @SqlStatement = ''
SELECT @SqlStatement = @SqlStatement
	+ 'SELECT * INTO ' + QUOTENAME(@AuditSchema) + '.' + QUOTENAME(TABLE_SCHEMA + '_' + TABLE_NAME) 
	+ ' FROM ' + QUOTENAME(TABLE_SCHEMA) + '.' + QUOTENAME(TABLE_NAME) + 
  -- This line is a cheap way to remove all identity properties from fields.
	+ ' UNION ALL SELECT * FROM ' + QUOTENAME(TABLE_SCHEMA) + '.' + QUOTENAME(TABLE_NAME) + ' WHERE 1 = 0' + CHAR(13)
	FROM #TempTables
-- PRINT @SqlStatement
EXEC (@SqlStatement)

-- Add Table Columns
PRINT ' -- Adding ' + QUOTENAME(@AuditSchema) + ' Property Columns -- '
SET @SqlStatement = ''
SELECT @SqlStatement = @SqlStatement
	+ 'ALTER TABLE ' + QUOTENAME(@AuditSchema) + '.' + QUOTENAME(TABLE_NAME)
	+ ' ADD [' + UPPER(@AuditSchema) + '_ID] INT CONSTRAINT [PK_' + @AuditSchema + '_' + TABLE_NAME + '] PRIMARY KEY IDENTITY(1,1),' 
	+ ' [' + UPPER(@AuditSchema) + '_ACTION] [varchar](20) NOT NULL CONSTRAINT [DF_' + @AuditSchema + '_' + TABLE_NAME + '_Action] DEFAULT ''INSERT'',' + 
	+ ' [' + UPPER(@AuditSchema) + '_TIME] [datetimeoffset] NOT NULL CONSTRAINT [DF_' + @AuditSchema + '_' + TABLE_NAME + '_Timestamp] DEFAULT SYSDATETIMEOFFSET()' + CHAR(13)
	FROM INFORMATION_SCHEMA.TABLES
		WHERE TABLE_SCHEMA = @AuditSchema
-- PRINT @SqlStatement
EXEC (@SqlStatement)

-- Create Triggers
SET @SqlStatement = ''
PRINT ' -- Creating ' + QUOTENAME(@TriggerLabel) + ' Triggers -- '

CREATE TABLE #TempActions (
	[Index] int IDENTITY(1,1) NOT NULL,
	[Action] varchar(20) NOT NULL,
	[Label] varchar(20) NOT NULL,
	[Collection] varchar(20) NOT NULL
)

INSERT INTO #TempActions ([Action],[Label],[Collection]) VALUES ('INSERT','Inserted','INSERTED')
INSERT INTO #TempActions ([Action],[Label],[Collection]) VALUES ('UPDATE','Updated','INSERTED')
INSERT INTO #TempActions ([Action],[Label],[Collection]) VALUES ('DELETE','Deleted','DELETED')

WHILE (Select Count(*) From #TempTables) > 0
BEGIN
    SELECT TOP 1 @TableName = [TABLE_NAME], @TableSchema = [TABLE_SCHEMA] FROM #TempTables
	PRINT (' -- Trigger Scripts for ' + @TableName)
	SET @Index = 0
	WHILE (Select Count(*) From #TempActions WHERE [Index] > @Index) > 0
	BEGIN
		SELECT TOP 1 @Action = [Action], @Label = [Label], @Collection = [Collection] FROM #TempActions WHERE [Index] > @Index
		SET @Index = @Index + 1
		SET @SqlStatement = '
			CREATE TRIGGER ' + QUOTENAME(@TableSchema) + '.[' + @TriggerLabel + '_' + @TableSchema + '_' + @TableName + '_' + @Label + ']
				ON ' + QUOTENAME(@TableSchema) + '.' + QUOTENAME(@TableName) + '
				AFTER ' + @Action + '
			AS 
			BEGIN
				INSERT INTO [audit].[' + @TableSchema + '_' + @TableName + ']
			   ([' + UPPER(@AuditSchema) + '_ACTION]';
		SELECT @SqlStatement = @SqlStatement + ',' + QUOTENAME([Column_Name])
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = TABLE_SCHEMA AND TABLE_NAME = @TableName
		SET @SqlStatement = @SqlStatement + ')
				SELECT ''' + @Label + '''';
		SELECT @SqlStatement = @SqlStatement + ',' + QUOTENAME([Column_Name])
			FROM INFORMATION_SCHEMA.COLUMNS
			WHERE TABLE_SCHEMA = TABLE_SCHEMA AND TABLE_NAME = @TableName
		SET @SqlStatement = @SqlStatement + '
				FROM ' + @Collection + '
			END';
		-- PRINT (@SqlStatement)
		EXEC (@SqlStatement)
	END
    DELETE FROM #TempTables WHERE [TABLE_NAME] = @TableName
END

DROP TABLE #TempTables
DROP TABLE #TempActions

COMMIT TRAN AUDIT_TRANSACTION
