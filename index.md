Large Data in R: Tools and Techniques
================
Updated December 02, 2021

-   [Environment Set Up](#environment-set-up)
-   [Nature and Scope of the Problem: What is Large
    Data?](#nature-and-scope-of-the-problem-what-is-large-data)
-   [Problem example](#problem-example)
-   [General strategies and
    principles](#general-strategies-and-principles)
    -   [Use a fast binary data storage format that enables reading data
        subsets](#use-a-fast-binary-data-storage-format-that-enables-reading-data-subsets)
    -   [Partition the data on disk to facilitate chunked access and
        computation](#partition-the-data-on-disk-to-facilitate-chunked-access-and-computation)
    -   [Only read in the data you
        need](#only-read-in-the-data-you-need)
    -   [Use streaming data tools and
        algorithms](#use-streaming-data-tools-and-algorithms)
    -   [Avoid unnecessarily storing or duplicating data in
        memory](#avoid-unnecessarily-storing-or-duplicating-data-in-memory)
    -   [Technique summary](#technique-summary)
-   [Solution example](#solution-example)
    -   [Convert .csv to parquet](#convert-csv-to-parquet)
    -   [Read and count Lyft records with
        arrow](#read-and-count-lyft-records-with-arrow)
    -   [Efficiently query taxi data with
        duckdb](#efficiently-query-taxi-data-with-duckdb)
-   [Your turn!](#your-turn)
-   [Additional resources](#additional-resources)

## Environment Set Up

The examples and exercises require R and several R packages. If you do
not yet have R installed you can do so following the instructions at
<https://cran.r-project.org/> . You may also wish to install Rstudio
from <https://www.rstudio.com/products/rstudio/download/#download>

Once you have R installed you can proceed to install the required
packages:

``` r
#install.packages(c("tidyverse", "data.table", "arrow", "duckdb"))
```

Once those are installed please take a moment to download and extract
the data used in the examples and exercises from
<https://www.dropbox.com/s/vbodicsu591o7lf/original_csv.zip?dl=1> (this
is a 1.3Gb zip file). These data record for-hire vehicle (aka “ride
sharing”) trips in NYC in 2020. Each row contains the record of a trip
and the variable descriptions can be found in
<https://www1.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_hvfhs.pdf>

You can download it using R if you wish:

``` r
if(!file.exists("original_csv.zip")) {
  download.file("https://www.dropbox.com/s/vbodicsu591o7lf/original_csv.zip?dl=1", "original_csv.zip")
  unzip("original_csv.zip")
}
```

## Nature and Scope of the Problem: What is Large Data?

Most popular data analysis software is designed to operate on data
stored in random access memory (aka just “memory” or “RAM”). This makes
modifying and copying data very fast and convenient, until you start
working with data that is too large for your computer’s memory system.
At that point you have two options: get a bigger computer or modify your
workflow to process the data more carefully and efficiently. This
workshop focuses on option two, using the `arrow` and `duckdb` packages
in R to work with data without necessarily loading it all into memory at
once.

A common definition of “big data” is “data that is too big to process
using traditional software”. We can use the term “large data” as a
broader category of “data that is big enough that you have to pay
attention to processing it efficiently”.

In a typical (traditional) program, we start with data on disk, in some
format. We read it in to memory, do some stuff to it on the CPU, store
the results of that stuff back in memory, then write those results back
to disk so they can be available for the future, as depicted below.

![Flow of Data in A Program](images/ComputerDataFlow.png) The reason
most data analysis software is designed to process data this way is
because “doing some stuff” is much much faster in RAM than it is if you
have to read values from disk every time you need them. The downside is
that RAM is much more expensive than disk storage, and typically
available in smaller quantities. Memory can only hold so much data and
we must either stay under that limit or buy more memory.

## Problem example

Grounding our discussion in a concrete problem example will help make
things clear. **I want to know how many Lyft rides were taken in New
York City during 2020**. The data is publicly available as documented at
<https://www1.nyc.gov/site/tlc/about/tlc-trip-record-data.page> and I
have made a subset available on dropbox as described in the Setup
section above for convenience. Documentation can be found at
<https://www1.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_hvfhs.pdf>

In order to demonstrate large data problems and solutions I’m going to
artificially limit my system to 8Gb of memory. This will allow is to
quickly see what happens when we reach the memory limit, and to look at
solutions to that problem without waiting for our program to read in
hundreds of Gb of data. (There is no need to follow along with this
step, the purpose is just to make sure we all know what happens when you
run out of memory.)

Start by looking at the file names and sizes:

``` r
fhvhv_csv_files <- list.files("original_csv", recursive=TRUE, full.names = TRUE)
data.frame(file = fhvhv_csv_files, size_Mb = file.size(fhvhv_csv_files) / 1024^2)
```

    ##                                               file   size_Mb
    ## 1  original_csv/2020/01/fhvhv_tripdata_2020-01.csv 1243.4975
    ## 2  original_csv/2020/02/fhvhv_tripdata_2020-02.csv 1313.2442
    ## 3  original_csv/2020/03/fhvhv_tripdata_2020-03.csv  808.5597
    ## 4  original_csv/2020/04/fhvhv_tripdata_2020-04.csv  259.5806
    ## 5  original_csv/2020/05/fhvhv_tripdata_2020-05.csv  366.5430
    ## 6  original_csv/2020/06/fhvhv_tripdata_2020-06.csv  454.5977
    ## 7  original_csv/2020/07/fhvhv_tripdata_2020-07.csv  599.2560
    ## 8  original_csv/2020/08/fhvhv_tripdata_2020-08.csv  667.6880
    ## 9  original_csv/2020/09/fhvhv_tripdata_2020-09.csv  728.5463
    ## 10 original_csv/2020/10/fhvhv_tripdata_2020-10.csv  798.4743
    ## 11 original_csv/2020/11/fhvhv_tripdata_2020-11.csv  698.0638
    ## 12 original_csv/2020/12/fhvhv_tripdata_2020-12.csv  700.6804

We can already guess based on these file sizes that with only 8 Gb of
RAM available we’re going to have a problem.

``` r
library(arrow)
fhvhv_data <- do.call(rbind, lapply(fhvhv_csv_files, read_csv_arrow))
```

    ## Error in eval(expr, envir, enclos): cannot allocate vector of size 7.6 Mb

Perhaps you’ve seen similar messages before. Basically it means that we
don’t have enough memory available to hold the data we want to work
with. How can we solve this problem?

If you’re working with data large enough to hit the dreaded
`cannot allocate vector` error when running your code, you’ve got a
problem. When using your naive workflow, you’re trying to fit too large
an object through the limit of your system’s memory.

![The Evergiven](images/bigboat.png) *An example of a large object
causing a bottleneck*

When you hit a memory bottleneck (assuming it’s not caused by a simple
to fix bug in your code), there is no magic quick solution to getting
around the issue. A number of resources that need to be considered when
developing any solution:

-   Development Time
-   Program Run Time
-   Computational Resources
    -   Number of Nodes
    -   Size of Nodes

A simple solution to a large data problem is just to throw more memory
at it. Depending on the problem, how often something needs to be run,
how long it’s expected to take, etc, that’s often a decent solution, and
minimizes the development time needed. However, compute time could still
be extended, and the resources required to run the program are quite
expensive. For reference, a single node with 8 cores and 100GB of memory
costs 300$/month on Amazon. If you need 400GB of memory (which some
naive approaches using the CMS data I’m familiar with do), the cost for
a single node goes up to 1200 per month.

## General strategies and principles

Recall that **I want to know how many Lyft rides were taken in New York
City during 2020**. Part of the problem with our first attempt is that
CSV files do not make it easy to quickly read subsets or select columns.
In this section we’ll spend some time identifying strategies for working
with large data and identify some tools that make it easy to implement
those strategies.

### Use a fast binary data storage format that enables reading data subsets

CSVs, TSVs, and similar *delimited files* are all *text-based formats*
that are typically used to store tabular data. Other more general
text-based data storage formats are in wide use as well, including XML
and JSON. These text-based formats have the advantage of being both
human and machine readable, but text is a relatively inefficient way to
store data, and loading it into memory requires a time-consuming parsing
process to separate out the fields and records.

As an alternative to text-based data storage formats, *binary formats*
have the advantage of being more space efficient on disk and faster to
read. They often employ advanced compression techniques, store metadata,
and allow fast selective access to data subsets. These substantial
advantages come at the cost of human readability; you cannot easily
inspect the contents of binary data files directly. If you are concerned
with reducing memory use or data processing time this is probably a
trade-off you are happy to make.

The `parquet` binary storage format is among the best currently
available. Support in R is provided by the `arrow` package. In a moment
we’ll see how we can use the `arrow` package to dramatically reduce the
time it takes to get data from disk to memory and back.

### Partition the data on disk to facilitate chunked access and computation

Memory requirements can be reduced by partitioning the data and
computation into chunks, running each one sequentially, and combining
the results at the end. It is common practice to partition (aka “shard”)
the data on disk storage to make this computational strategy more
natural and efficient. For example, the taxi data is already partitioned
the data by month, i.e., there is a separate data file for each
year/month.

### Only read in the data you need

If we think carefully about it we’ll see that our previous attempt to
process the taxi data by reading in all the data at once was wasteful.
Not all the rows are Lyft rides, and the only column I really need is
the one that tells me if the ride was an Lyft or not. I can perform the
computation I need by only reading in that one column, and only the rows
for which the `Hvfhs_license_num` column is equal to `HV0005` (Lyft).

### Use streaming data tools and algorithms

It’s all fine and good to say “only read the data you need”, but how do
you actually do that? Unless you have full control over the data
collection and storage process chances are good that your data provider
included a bunch of stuff you don’t need. The key is to find a data
selection and filtering tool that works with streamed data so that you
can access subsets without ever loading data you don’t need into memory.
Both the `arrow` and `duckdb` R packages support this type of workflow
and can dramatically reduce the time and hardware requirements for many
computations.

### Avoid unnecessarily storing or duplicating data in memory

It is also important to pay some attention to storing and processing
data efficiently once we have it loaded in memory. R likes to make
copies of the data, and while it does try to avoid unnecessary
duplication this process can be unpredictable. At a minimum you can
remove or avoid storing intermediate results you don’t need and take
care not to make copies of your data structures unless you have to. The
`data.table` package additionally makes it easier to efficiently modify
R data objects in-place, reducing the risk of accidentally or
unknowingly duplicating large data structures.

### Technique summary

We’ve accumulated a list of helpful techniques! To review:

-   Use a fast binary data storage format that enables reading data
    subsets
-   Partition the data on disk to facilitate chunked access and
    computation
-   Only read in the data you need
-   Use streaming data tools and algorithms
-   Avoid unnecessarily storing or duplicating data in memory

Using these techniques will allow us to overcome the memory limitation
we ran up against before, and finally answer the question “**How many
Lyft rides were taken in New York City during 2020?**

## Solution example

Now that we have some theoretical foundations to build on we can start
putting these techniques into practice.

### Convert .csv to parquet

The first step is to take the slow and inefficient text-based data
provided by the city of New York convert it to parquet using the `arrow`
package. This is a one-time up-front cost that may be expensive in terms
of time and/or computational resources. If you plan to work with the
data a lot it will be well worth it because it allows subsequent reads
to be faster and more memory efficent.

``` r
library(arrow)

if(!dir.exists("converted_parquet")) {
  dir.create("converted_parquet")
  ## this doesn't yet read the data in, it only creates a connection
  csv_ds <- open_dataset("original_csv", 
                         format = "csv",
                         partitioning = c("year", "month"))
  write_dataset(csv_ds, 
                "converted_parquet", 
                format = "parquet",
                partitioning = c("year", "month"))
}
```

This conversion is relatively easy (even with limited memory) because
the data provider is already using one of our strategies, i.e., they
partitioned the data by year/month. This allows us to convert each file
one at a time, without ever needing to read in all the data at once.

We also took some care to partition the data into `year/month`
sub-directories using what is known as “hive-style” partitioning. This
is important because it makes it easy for `arrow` to automatically
recognize the partitions.

We can look at the converted files and compare the naming scheme and
storage requirements to the original CSV data.

``` r
fhvhv_files <- list.files("converted_parquet", full.names = TRUE, recursive = TRUE)
data.frame(csv_file = fhvhv_csv_files, 
           parquet_file = fhvhv_files, 
           csv_size_Mb = file.size(fhvhv_csv_files) / 1024^2, 
           parquet_size_Mb = file.size(fhvhv_files) / 1024^2)
```

    ##                                           csv_file
    ## 1  original_csv/2020/01/fhvhv_tripdata_2020-01.csv
    ## 2  original_csv/2020/02/fhvhv_tripdata_2020-02.csv
    ## 3  original_csv/2020/03/fhvhv_tripdata_2020-03.csv
    ## 4  original_csv/2020/04/fhvhv_tripdata_2020-04.csv
    ## 5  original_csv/2020/05/fhvhv_tripdata_2020-05.csv
    ## 6  original_csv/2020/06/fhvhv_tripdata_2020-06.csv
    ## 7  original_csv/2020/07/fhvhv_tripdata_2020-07.csv
    ## 8  original_csv/2020/08/fhvhv_tripdata_2020-08.csv
    ## 9  original_csv/2020/09/fhvhv_tripdata_2020-09.csv
    ## 10 original_csv/2020/10/fhvhv_tripdata_2020-10.csv
    ## 11 original_csv/2020/11/fhvhv_tripdata_2020-11.csv
    ## 12 original_csv/2020/12/fhvhv_tripdata_2020-12.csv
    ##                                           parquet_file csv_size_Mb
    ## 1   converted_parquet/year=2020/month=1/part-0.parquet   1243.4975
    ## 2  converted_parquet/year=2020/month=10/part-0.parquet   1313.2442
    ## 3  converted_parquet/year=2020/month=11/part-0.parquet    808.5597
    ## 4  converted_parquet/year=2020/month=12/part-0.parquet    259.5806
    ## 5   converted_parquet/year=2020/month=2/part-0.parquet    366.5430
    ## 6   converted_parquet/year=2020/month=3/part-0.parquet    454.5977
    ## 7   converted_parquet/year=2020/month=4/part-0.parquet    599.2560
    ## 8   converted_parquet/year=2020/month=5/part-0.parquet    667.6880
    ## 9   converted_parquet/year=2020/month=6/part-0.parquet    728.5463
    ## 10  converted_parquet/year=2020/month=7/part-0.parquet    798.4743
    ## 11  converted_parquet/year=2020/month=8/part-0.parquet    698.0638
    ## 12  converted_parquet/year=2020/month=9/part-0.parquet    700.6804
    ##    parquet_size_Mb
    ## 1        190.26387
    ## 2        125.17837
    ## 3        110.92145
    ## 4        111.67697
    ## 5        198.87074
    ## 6        127.53637
    ## 7         48.32047
    ## 8         64.17768
    ## 9         76.45972
    ## 10        97.99151
    ## 11       107.80694
    ## 12       115.25221

As expected, the binary parquet storage format is much more compact than
the text-based CSV format. This is one reason that reading parquet data
is so much faster:

``` r
## tidyverse csv reader
system.time(invisible(readr::read_csv(fhvhv_csv_files[[1]], show_col_types = FALSE)))
```

    ##    user  system elapsed 
    ##  53.973   2.423  19.099

``` r
## arrow package parquet reader
system.time(invisible(read_parquet(fhvhv_files[[1]])))
```

    ##    user  system elapsed 
    ##   3.038   1.179   2.185

### Read and count Lyft records with arrow

The `arrow` package makes it easy to read and process only the data we
need for a particular calculation. It allows us to use the partitioned
data directories we created earlier as a single dataset and to query it
using the `dplyr` verbs many R users are already familiar with.

Start by creating a dataset representation from the partitioned data
directory:

``` r
fhvhv_ds <- open_dataset("converted_parquet",
                         schema = schema(hvfhs_license_num=string(),
                                         dispatching_base_num=string(),
                                         pickup_datetime=string(),
                                         dropoff_datetime=string(),
                                         PULocationID=int64(),
                                         DOLocationID=int64(),
                                         SR_Flag=int64(),
                                         year=int32(),
                                         month=int32()))
```

Because we have hive-style directory names `open_dataset` automatically
recognizes the partitions. Note that usually we do not need to manually
specify the `schema`, we do so here to work around an issue with
`duckdb` support.

Importantly, `open_dataset` doesn’t actually read the data into memory.
It just opens a connection to the dataset and makes it easy for us to
query it. Finally, we can compute the number of NYC Lyft trips in 2020,
even on a machine with limited memory:

``` r
library(dplyr, warn.conflicts = FALSE)

fhvhv_ds %>%
  filter(hvfhs_license_num == "HV0005") %>%
  select(hvfhs_license_num) %>%
  collect() %>%
  summarize(total_Lyft_trips = n())
```

    ## # A tibble: 1 × 1
    ##   total_Lyft_trips
    ##              <int>
    ## 1         37250101

Note that `arrow` datasets do not support `summarize` natively, that is
why we call `collect` first to actually read in the data.

The `arrow` package makes it fast and easy to query on-disk data and
read in only the fields and records needed for a particular computation.
This is a tremendous improvement over the typical R workflow, and may
well be all you need to start using your large datasets more quickly and
conveniently, even on modest hardware.

### Efficiently query taxi data with duckdb

If you need even more speed and convenience you can try the `duckdb`
package. It allows you to query the same parquet datasets partitioned on
disk as we did above. You can use either SQL statements via the `DBI`
package or tidyverse style verbs using `dbplyr`. Let’s see how it works.

First we create a `duckdb` table from our `arrow` dataset.

``` r
library(duckdb)
library(DBI)
library(dplyr)

con <- DBI::dbConnect(duckdb::duckdb())
to_duckdb(fhvhv_ds, con, "fhvhv")
```

    ## # Source:   table<fhvhv> [?? x 9]
    ## # Database: duckdb_connection
    ##    hvfhs_license_num dispatching_base_num pickup_datetime     dropoff_datetime  
    ##    <chr>             <chr>                <chr>               <chr>             
    ##  1 HV0003            B02864               2020-01-01 00:45:3… 2020-01-01 01:02:…
    ##  2 HV0003            B02682               2020-01-01 00:47:5… 2020-01-01 00:53:…
    ##  3 HV0003            B02764               2020-01-01 00:04:3… 2020-01-01 00:21:…
    ##  4 HV0003            B02764               2020-01-01 00:26:3… 2020-01-01 00:33:…
    ##  5 HV0003            B02764               2020-01-01 00:37:4… 2020-01-01 00:46:…
    ##  6 HV0003            B02764               2020-01-01 00:49:2… 2020-01-01 01:07:…
    ##  7 HV0003            B02870               2020-01-01 00:21:1… 2020-01-01 00:36:…
    ##  8 HV0003            B02870               2020-01-01 00:38:2… 2020-01-01 00:42:…
    ##  9 HV0003            B02870               2020-01-01 00:46:2… 2020-01-01 01:09:…
    ## 10 HV0003            B02836               2020-01-01 00:15:3… 2020-01-01 00:23:…
    ## # … with more rows, and 5 more variables: PULocationID <dbl>,
    ## #   DOLocationID <dbl>, SR_Flag <dbl>, year <int>, month <int>

The `duckdb` table can be queried using tidyverse style verbs or SQL.

``` r
## number of Lyft trips, tidyverse style
tbl(con,"fhvhv") %>%
  filter(hvfhs_license_num == "HV0005") %>%
  select(hvfhs_license_num) %>%
  count()
```

    ## # Source:   lazy query [?? x 1]
    ## # Database: duckdb_connection
    ##          n
    ##      <dbl>
    ## 1 37250101

``` r
## number of Lyft trips, SQL style
y <- dbSendQuery(con, "SELECT COUNT(*) FROM fhvhv WHERE hvfhs_license_num=='HV0005';")
dbFetch(y)
```

    ##   count_star()
    ## 1     37250101

The main advantages of `duckdb` are that it has full SQL support,
supports streaming aggregation, and allows you to set memory limits and
is optimized for speed.

## Your turn!

Now that you understand some of the basic techniques for working with
large data and have seen an example, you can start to apply what you’ve
learned. Using the same taxi data, try answering the following
questions:

-   What percentage of trips are made by Lyft?
-   In which month did Lyft log the most trips?

Documentation for these data can be found at
<https://www1.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_hvfhs.pdf>

## Additional resources

-   [Arrow R package documentation](https://arrow.apache.org/docs/r/)
-   [Arrow Python package
    documentation](https://arrow.apache.org/docs/python/)
-   [DuckDB documentation](https://duckdb.org/docs/)
-   
