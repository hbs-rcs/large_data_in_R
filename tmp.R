## Purpose: Demonstrate how to connect to and interact with
##          the MariaDB database on the compute grid.
## Authors: Christine Rivera and Ista Zahn
## Updated: March 19th 2020

# Load libraries of interest (install if needed)
library(DBI)
library(dplyr)


####################################################################
# Connect to a database using connection info specified in .my.cnf #
####################################################################

# Specify the location of your .my.cnf file.
# See https://grid.rcs.hbs.org/db-configuration-files for details.
myfile= path.expand("~/.my.cnf") # "~/" means "Home directory"

# Specify the mysql group to use. For example, "mysql" corresponds
# to the '[mysql]' group in .my.cnf
mygroup= 'mysql'

# Connect to mysql as defined in .my.cnf.
con <- dbConnect(RMariaDB::MariaDB(), 
                 default.file= myfile, 
                 group= mygroup
                 #, dbname= 'mydatabase' # if you don't specify a database in .my.cnf specify it here
)

# As an alternative to putting connection information in a .my.cnf file 
# you can hard code your connection information.
## con2 <- dbConnect(RMariaDB::MariaDB(),
##                   user= "", 
##                   password= "",
##                   host= "", 
##                   port= 3306,
##                   dbname= "",
##                   ssl.ca= "")

## See https://rmariadb.r-dbi.org/ for details about connecting to MariaDB databases.


######################################################
# List tables, read and write data using DBI package #
######################################################

# List available databases and tables.
dbListObjects(con)

# List tables in connected database.
dbListTables(con)

# Write data to table (commented for safety, will create table in connected database)
## data(mtcars) # built-in R data set
## dbWriteTable(con, "sample_mtcars_table", mtcars)
## dbListTables(con)

# List fields in a table.
dbListFields(con, "sample_mtcars_table")

# Read an entire table.
df1 <- dbReadTable(con, "sample_mtcars_table")

# Execute arbitrary SQL queries. 
res <- dbSendQuery(con, "SELECT * FROM sample_mtcars_table limit 5")
# Fetch data produced by the query in `res`
df2 <- dbFetch(res, n= -1)

# Clear the results.
dbClearResult(res)

# For larger tables you may wish to get results a chunk at a time
#res <- dbSendQuery(con, "SELECT * FROM mtcars WHERE cyl = 4")
#while(!dbHasCompleted(res)){
#  chunk <- dbFetch(res, n = 5)
#  print(nrow(chunk))
#}

# Disconnect from the database.
dbDisconnect(con)

## See https://dbi.r-dbi.org/ for details about the DBI system in R.

####################################################
# Simplified dplyr database interface using dbplyr #
####################################################

## You can use a simplified dplyr database interface instead of DBI if you prefer.
## Create a connection named `con` using DBI and RMariaDB as before:

con <- dbConnect(RMariaDB::MariaDB(), 
                 default.file= myfile,
                 group= mygroup
)

# List tables in a db.
dbListTables(con)

# Create a table reference.
cars <- tbl(con, "sample_mtcars_table")

# Interact with `cars` mostly as you would with a local tbl

powerful_cars <- cars %>%
  select(mpg, hp) %>%
  filter(hp >= 200)

## Disconnect from the database
dbDisconnect(con)