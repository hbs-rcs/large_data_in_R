Large Data in R: Tools and Techniques
================
Updated December 01, 2021

-   [Environment Set Up](#environment-set-up)
-   [Nature and Scope of the Problem: What is Large
    Data?](#nature-and-scope-of-the-problem-what-is-large-data)
-   [Problem example](#problem-example)
-   [General strategies and
    principles](#general-strategies-and-principles)
    -   [Use a fast binary data storage format that enables reading data
        subsets](#use-a-fast-binary-data-storage-format-that-enables-reading-data-subsets)
    -   [Partition (aka “shard”) the data on disk to facilitate chunked
        access and
        computation](#partition-aka-shard-the-data-on-disk-to-facilitate-chunked-access-and-computation)
    -   [Only read in the data you
        need](#only-read-in-the-data-you-need)
    -   [Use streaming data tools and algorithms where
        available](#use-streaming-data-tools-and-algorithms-where-available)
    -   [Avoid unnecessarily storing or duplicating data in
        memory](#avoid-unnecessarily-storing-or-duplicating-data-in-memory)
    -   [Technique summary](#technique-summary)
-   [Solution example](#solution-example)
    -   [Convert .csv to parquet](#convert-csv-to-parquet)
    -   [Read just the Uber records and count
        them](#read-just-the-uber-records-and-count-them)
    -   [Use the duckdb package for streaming
        aggregation](#use-the-duckdb-package-for-streaming-aggregation)
-   [Other Useful Tools](#other-useful-tools)
    -   [3.5 Other Approaches](#35-other-approaches)
    -   [Databases](#databases)
    -   [MPI Interfaces on HPC](#mpi-interfaces-on-hpc)
    -   [Spark](#spark)
-   [Additional Resources](#additional-resources)

## Environment Set Up

**PLEASE DO THIS BEFORE THE WORKSHOP**

The examples and exercises require R and several R packages. If you do
not yet have R installed you can do so following the instructions at
<https://cran.r-project.org/> . You may also wish to install Rstudio
from <https://www.rstudio.com/products/rstudio/download/#download>

Once you have R installed you can proceed to install the required
packages:

``` r
install.packages(c("tidyverse", "duckdb", "arrow"))
```

Once those are is installed please take a moment to download the data
used in the examples and exercises. You can do it from R if you wish:

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

![Flow of Data in A Program](images/Computer%20Data%20Flow.png) The
reason most data analysis software is designed to process data this way
is because “doing some stuff” is much much faster in RAM than it is if
you have to read values from disk every time you need them. The downside
is that RAM is much more expensive than disk storage, and typically
available in smaller quantities. Memory can only hold so much data and
we must either stay under that limit or buy more memory.

## Problem example

Grounding our discussion in a concrete problem example will help make
things clear. **I want to know how many Uber rides were taken in New
York City during 2020**. The data is publicly available as documented at
<https://www1.nyc.gov/site/tlc/about/tlc-trip-record-data.page> and I
have made a subset available on dropbox as described in the Setup
section above for convenience. Documentation can be found at
<https://www1.nyc.gov/assets/tlc/downloads/pdf/data_dictionary_trip_records_hvfhs.pdf>

In order to demonstrate large data problems and solutions I’m going to
artificially limit my system to 8Gb of memory. This will allow is to
quickly see what happens when we reach the memory limit, and to look at
solutions to that problem without waiting for our program to read in
hundreds of Gb of data. On Linux memory can be artificially limited
using the `ulimit` command before staring R, e.g., `ulimit -Sv 8000000`.

Start by looking at the file names and sizes:

``` r
fhvhv_csv_files <- list.files("original_csv", full.names = TRUE)
data.frame(file = fhvhv_csv_files, size_Mb = file.size(fhvhv_csv_files) / 1024^2)
```

    ##                                       file   size_Mb
    ## 1  original_csv/fhvhv_tripdata_2020-01.csv 1243.4975
    ## 2  original_csv/fhvhv_tripdata_2020-02.csv 1313.2442
    ## 3  original_csv/fhvhv_tripdata_2020-03.csv  808.5597
    ## 4  original_csv/fhvhv_tripdata_2020-04.csv  259.5806
    ## 5  original_csv/fhvhv_tripdata_2020-05.csv  366.5430
    ## 6  original_csv/fhvhv_tripdata_2020-06.csv  454.5977
    ## 7  original_csv/fhvhv_tripdata_2020-07.csv  599.2560
    ## 8  original_csv/fhvhv_tripdata_2020-08.csv  667.6880
    ## 9  original_csv/fhvhv_tripdata_2020-09.csv  728.5463
    ## 10 original_csv/fhvhv_tripdata_2020-10.csv  798.4743
    ## 11 original_csv/fhvhv_tripdata_2020-11.csv  698.0638
    ## 12 original_csv/fhvhv_tripdata_2020-12.csv  700.6804

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

![The Evergiven (please put her back)](images/big%20boat.jpg) *An
example of a large object causing a bottleneck*

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

Recall that **I want to know how many Uber rides were taken in New York
City during 2020**. Part of the probelm with our first attempt is that
CSV files do not make it easy to quickly read subsets or select columns.

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

### Partition (aka “shard”) the data on disk to facilitate chunked access and computation

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
Not all the rows are Uber rides, and the only column I really need is
the one that tells me if the ride was an Uber or not. I can perform the
computation I need by only reading in that one column, and only the rows
for which the `Hvfhs_license_num` column is equal to `HV0003` (Uber).

### Use streaming data tools and algorithms where available

Even when taking care to read into memory only the data we need, we may
find that we still don’t have enough memory. In this case we may have to
consider using a different tool and/or changing our algorithm to use
*streaming* data, i.e., to compute the desired result without every
having loaded all the data used in the calculation into memory at once.
The `duckdb` R package will enable us to perform streaming SQL queries,
enabling us to perform many summary statistics without ever manually
reading data into memory at all.

### Avoid unnecessarily storing or duplicating data in memory

It is also important to pay some attention to storing and processing
data efficiently once we have it loaded in memory. R likes to make
copies of the data, and while it does try to avoid unnecessary
duplication this process can be unpredictable. At a minimum you can
remove or avoid storing intermediate results you don’t need and take
care not to make copies of your data structures unless you have to.

### Technique summary

We’ve accumulated quite a list of helpful techniques! To review:

-   Use a fast binary data storage format that enables reading data
    subsets
-   Partition (aka “shard”) the data on disk to facilitate chunked
    access and computation
-   Only read in the data you need
-   Use streaming data tools and algorithms where available
-   Avoid unnecessarily storing or duplicating data in memory

Using these techniques will allow us to overcome the memory limitation
we ran up against before, and finally answer the question “**How many
Uber rides were taken in New York City during 2020?**

## Solution example

Now that we have some theoretical foundations to build on we can start
putting these techniques into practice.

### Convert .csv to parquet

The first step is to take the slow and inefficient text-based data
provided by the city of New York convert it to parquet using the `arrow`
package. This is a one-time up-front cost that may be expensive in terms
of time and/or computational resources. If you plan to work with the
data a lot it will be well worth it because it allows subsequent reads
to be fast and selective.

``` r
library(arrow)

## This is the most complicated section of code in this workshop.
## If your eyes start to glaze over, stick with it! It's not as complicated
## as it might look, and things get better from here.
if(!dir.exists("converted_parquet")) {
  ## create vector of output file names
  outnames <- paste("converted_parquet", 
                    "2020", 
                    sprintf("%02d", 1:12), 
                    "fhvhv_tripdata.parquet", 
                    sep = "/")
  ## convert csv to parquet
  for (i in 1:length(fhvhv_csv_files)) {
    dir.create(dirname(outnames[i]),recursive = TRUE, showWarnings = FALSE)
    write_parquet(read_csv_arrow(fhvhv_csv_files[i], as_data_frame=FALSE), 
                  outnames[i])
    gc()
  }
}
```

This conversion is relatively easy (even with our artificially limited
memory) because the upstream data provider are already using one of our
strategies, i.e., they partitioned the data by year/month. This allows
us to convert each file one at a time, without ever needing to read in
all the data at once.

We also took some care to partition the data into `year/month`
sub-directories. This is important because arrow treats data stored in
this way as a unified data set even though it is partioned into multiple
files.

We can look at the converted files and compare the storage requirements
to the original CSV data.

``` r
fhvhv_files <- list.files("converted_parquet", full.names = TRUE, recursive = TRUE)
data.frame(csv_file = basename(fhvhv_csv_files), 
           parquet_file = basename(fhvhv_files), 
           csv_size_Mb = file.size(fhvhv_csv_files) / 1024^2, 
           parquet_size_Mb = file.size(fhvhv_files) / 1024^2)
```

    ##                      csv_file           parquet_file csv_size_Mb
    ## 1  fhvhv_tripdata_2020-01.csv fhvhv_tripdata.parquet   1243.4975
    ## 2  fhvhv_tripdata_2020-02.csv fhvhv_tripdata.parquet   1313.2442
    ## 3  fhvhv_tripdata_2020-03.csv fhvhv_tripdata.parquet    808.5597
    ## 4  fhvhv_tripdata_2020-04.csv fhvhv_tripdata.parquet    259.5806
    ## 5  fhvhv_tripdata_2020-05.csv fhvhv_tripdata.parquet    366.5430
    ## 6  fhvhv_tripdata_2020-06.csv fhvhv_tripdata.parquet    454.5977
    ## 7  fhvhv_tripdata_2020-07.csv fhvhv_tripdata.parquet    599.2560
    ## 8  fhvhv_tripdata_2020-08.csv fhvhv_tripdata.parquet    667.6880
    ## 9  fhvhv_tripdata_2020-09.csv fhvhv_tripdata.parquet    728.5463
    ## 10 fhvhv_tripdata_2020-10.csv fhvhv_tripdata.parquet    798.4743
    ## 11 fhvhv_tripdata_2020-11.csv fhvhv_tripdata.parquet    698.0638
    ## 12 fhvhv_tripdata_2020-12.csv fhvhv_tripdata.parquet    700.6804
    ##    parquet_size_Mb
    ## 1        221.37902
    ## 2        232.82627
    ## 3        143.00006
    ## 4         48.04683
    ## 5         66.89160
    ## 6         82.20870
    ## 7        107.53598
    ## 8        119.42568
    ## 9        130.06381
    ## 10       142.01453
    ## 11       124.23919
    ## 12       125.16402

As expected, the binary parquet storage format is much more compact than
the text-based CSV format. This is one reason that reading parquet data
is so much faster:

``` r
## standard R csv reader
system.time(invisible(readr::read_csv(fhvhv_csv_files[[1]], show_col_types = FALSE)))
```

    ##    user  system elapsed 
    ##  46.971   3.090  17.389

``` r
## fread from the data.table package
system.time(invisible(data.table::fread(fhvhv_csv_files[[1]])))
```

    ##    user  system elapsed 
    ##   4.945   0.615   3.013

``` r
## arrow package csv reader
system.time(invisible(read_csv_arrow(fhvhv_csv_files[[1]])))
```

    ##    user  system elapsed 
    ##   6.448   2.414   4.840

``` r
## arrow package parquet reader
system.time(invisible(read_parquet(fhvhv_files[[1]])))
```

    ##    user  system elapsed 
    ##   2.335   1.369   2.097

### Read just the Uber records and count them

The `arrow` package makes it easy to read and process only the data we
need for a particular calculation. It allows us to use the partitioned
data directories we created earlier as a single dataset and to query it
using the `dplyr` verbs many R users are already familiar with.

Start by creating a dataset representation from the partitioned data
directory:

``` r
fhvhv_ds <- open_dataset("converted_parquet", partitioning = c("year", "month"))
```

the `year` and `month` partitioning argument corresponds to the two
levels of the directory structure we created earlier.

Importantly, `open_dataset` doesn’t actually read the data into memory.
It just opens a connection to the dataset and makes it easy for us to
query it. Finally we can compute the number of NYC Uber trips in 2020,
even on a machine with limited memory:

``` r
library(dplyr, warn.conflicts = FALSE)

fhvhv_ds %>%
  filter(hvfhs_license_num == "HV0003") %>%
  select(hvfhs_license_num) %>%
  collect() %>%
  summarize(total_uber_trips = n())
```

    ## # A tibble: 1 × 1
    ##   total_uber_trips
    ##              <int>
    ## 1        103112054

Note that `arrow` datasets do not support `summarize` natively, that is
why we call `collect` first to actually read in the data.

### Use the duckdb package for streaming aggregation

The `arrow` package makes it fast and easy to query on-disk data and
read in only the fields and records needed for a particular computation.
This is a tremendous improvement over the typical R workflow, and may
well be all you need to start using your large datasets more quickly and
conveniently, even on modest hardware. If you need even more speed and
convienence you can try the `duckdb` package. It allows you to query the
same parquet datasets partitioned on disk as we did above. In many cases
it even allows you to aggregate your data in a streaming fashion,
meaning that you never have to load substantial data into memory at all.
Let’s see how it works.

``` r
library(duckdb)
```

    ## Loading required package: DBI

## Other Useful Tools

-   Apache Spark/Parquet Datasets are another useful tool supporting
    data sharding. They use the file system, with directory names
    corresponding to values of variables, similar to how we used groups
    with hdf5 files above. More information can be found
    [here](https://cran.r-project.org/web/packages/arrow/vignettes/dataset.html).

-   [vroom](https://vroom.r-lib.org/articles/vroom.html#reading-compressed-files-1)
    is a package designed for super fast reading of tabular data files.
    It provides similar functionality to `readr` but with improved
    performance, and additional features (such as supporting column
    selection). It works by indexing your data rather than reading it in
    to memory all at once, and then just reading only what you use in to
    memory. This reduces the memory impact when you only need access to
    a partial file, but still threatens to cause memory issues if not
    used carefully.

### 3.5 Other Approaches

The approaches we’ve covered today work with minimal infrastructure, and
can easily work on both personal computers and in cluster environments.
There are other techniques out there, all of which merit their own
workshops, we’ll briefly touch on these just to give people a sense of
what’s out there.

Keep in mind that with these solutions, there is typically an increase
in initial development time and a decrease in portability. It’s always
important to keep in mind the needs of your application when planning
your solutions.

### Databases

SQL based database systems are the classic solution for dealing with
complex data that exceeds the size of memory. The DBMS handles
calculations of partial products in memory as well as handling
optimization of the query plan. However most database systems require
dedicated servers and are often not the best fit for academic research
projects.

That said, we can use systems like sqlite to create file based databases
that can support data operations without the use of significant memory.
Databases, whether sqlite or a more powerful implementation have the
advantage of basically all using a form of SQL as their main language.
SQL is defined by an international standard, and basically all computer
languages and systems have pre-built tools for interacting with SQL
databases.

Database development and optimization is its own field of engineering,
with enough material and nuance to require multiple university courses.

### MPI Interfaces on HPC

One of the simplest solutions to big data problems (when working on a
cluster system, and/or computing cost isn’t a major concern) is to
acquire more memory. However, with most tools in HPC computing
environments we are physically limited by the total amount of memory
available on a single node.

[MPI](https://hpc-wiki.info/hpc/MPI) provides a way around this limit by
providing a method for separate nodes to pass messages to each other and
effectively serve as a shared memory system, with many child nodes being
coordinated by a controlling parent node. Developing a program to work
using MPI is a complex development process, although the [R MPI
library](https://docs.rc.fas.harvard.edu/kb/r-mpi/) does exist to
simplify integration between the base MPI library and R.

### Spark

[Apache Spark](https://spark.apache.org/) is a “a fast and general
processing engine compatible with Hadoop data.” Spark clusters can
support working with data larger than memory (and can automatically
handle memory overflows by putting data on disk as necessary). Spark can
be set up locally on a personal computer, or run on a cluster system
managed by Kubernetes.

[Sparklyr](https://spark.rstudio.com/) is a R library that provides an
interface for Spark and allows for `dplyr` like syntax to be used with
Spark objects and provides a wrapper around Spark’s built in Machine
learning libraries.

For more information on working with Spark in R, please see the free
book [Mastering Spark in R](https://therinspark.com/).

## Additional Resources

-   [Hadley Wickham’s Advanced R](https://adv-r.hadley.nz/index.html)
-   [Data.Table Syntax Cheat
    Sheet](https://www.datacamp.com/community/tutorials/data-table-cheat-sheet)
-   [Mastering Spark in R](https://therinspark.com/)
-   [R HDF5
    Vignette](https://bioconductor.org/packages/release/bioc/vignettes/rhdf5/inst/doc/rhdf5.html)
