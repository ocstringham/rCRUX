#load the necessary libraries
library(lubridate)
library(XML)
library(httr)
library(tidyverse)
library(tidyr)
library(dplyr)
library(ape)
library(tibble)
library(rlist)
library(rlang)
library(taxonomizr)
library(data.table)
library(RCurl)
library(parallel)

#Make sure you are using the custom version of primerTree
#See readme for installation instructions
library(primerTree)

################################################################################
#Ancillary Functions

###################
# Function uses taxonimizer to pull taxonomy from accessions and also collects taxids.   
# Why not just use taxids recovered from blast?  Well blast sometimes pulls multiple taxids.  How annoying....

get_taxonomizer_from_accession <- function(input, accessionTaxa_path){
  input_taxid <<- accessionToTaxa(input$accession, accessionTaxa_path)
  
  input_taxonomy <<- getTaxonomy(input_taxid,accessionTaxa_path,desiredTaxa = c("species","superkingdom", "kingdom", "phylum", "subphylum", "superclass", "class", "subclass", "order", "family", "subfamily", "genus", "infraorder", "subcohort", "superorder", "superfamily", "tribe", "subspecies", "subgenus", "species group", "parvorder", "varietas"))
  
  input_taxonomy <<- cbind('accession'=input$accession, 'taxID'=input_taxid, input_taxonomy)
  input_taxonomy <<- as_tibble(input_taxonomy)
  # Join the blast output and taxonomy tibbles
  return(full_join(input, input_taxonomy, by = "accession"))
}

##########################
# Function to make and save histograms in .csv files
#
make_hist_save_pdf <- function(infile, description,  file_out_dir, Metabarcode_name){
  pdf(paste0(file_out_dir, Metabarcode_name, description,".pdf"), height = 4, width = 6, onefile=T)
  plot <- hist(infile)
  print(plot)
  dev.off()
}

###################
# Select the odd numbers from a vector

odds <- function(x) subset(x, x %% 2 != 0)

##########################
# Function to save data in .csv files
#

save_output_as_csv <- function(file_name, description, file_out, Metabarcode){
  write_to = paste0(file_out, Metabarcode, description, ".csv")
  return(write.table(file_name, file = write_to, row.names=FALSE, sep = ","))
}

################################################################################
# Function to attempt parse_primer_hits and fail less loudly
# Equivalent to parse_primer_hits() if the argument is a legal argument
# If the argument is illegal, returns FALSE, which the program can use to respond appropriately

try_parse_hits <- function(response) {
  tryCatch(parse_primer_hits(response),
           error = function(e) {
             return(e)
           },
           finally = {})
}


################################################################################
#get_blast_seeds

get_blast_seeds <- function(forward_primer, reverse_primer,
                            file_out_dir, Metabarcode_name,
                            accessionTaxa, 
                            organism, mismatch = 3,
                            minimum_length = 5, maximum_length = 500,
                            primer_specificity_database = "nt", ...,
                            return_table = TRUE){
  

  
  # create url, a list of url strings returned by primer_search
  url <- list()
  for(e in organism) {
    # search for amplicons using f and r primers
    primer_search_results <- primer_search(forward_primer, reverse_primer,
                                           organism = e,
                                           primer_specificity_database = primer_specificity_database, 
                                           ...)
    for(f in primer_search_results) {
      url <- append(url, f$url)
    }
  }
  
  # make dataframe
  colnames <- c("gi",
                "accession",
                "product_length",
                "mismatch_forward",
                "mismatch_reverse",
                "forward_start",
                "forward_stop",
                "reverse_start",
                "reverse_stop",
                "product_start",
                "product_stop")
  
  # set up empty tibbles and variables...
  primer_search_blast_out <- data.frame(matrix(ncol = 11, nrow = 0))
  colnames(primer_search_blast_out) <- colnames
  # add break an error messagr -> check primers or use highr taxpnomic rank
  
  for (e in url){
    primer_search_response <- httr::GET(e)
    
    #parse the blast hits into something human friendly
    primer_search_blast_out_temp <- try_parse_hits(primer_search_response)
    if(class(primer_search_blast_out_temp) == "data.frame") {
      primer_search_blast_out <- rbind(primer_search_blast_out, primer_search_blast_out_temp)
    }
    else {
      message(paste(e, " is not a valid url. It will be ignored."))
      message(primer_search_blast_out_temp)
      writeLines("")
    }
    
    #print useful metadata
    print(paste('Response URL: ', e))
    print(paste('Response Size: ', object.size(primer_search_response)))
    
  }
  
  #remove duplicate rows from primer_search_blast_out
  primer_search_blast_out <- distinct(primer_search_blast_out)
  
  #make primer_search_blast_out df a tibble
  as_tibble(primer_search_blast_out)
  filter_long_and_short_reads <- primer_search_blast_out %>%
    filter(mismatch_forward <= mismatch) %>%
    filter(mismatch_reverse <= mismatch) %>%
    filter(product_length >= minimum_length) %>%
    filter(product_length <= maximum_length) %>%
    mutate(amplicon_length = product_length - nchar(forward_primer) - nchar(reverse_primer))
  
  # fetch taxonomy associated with the Blast results and arange in alphabetical order starting with species > genus > family > order > class > phylum > superkingdom  - not sure this speeds up blast, but if you are ocd it makes you feel better about life :)
  
  bla <- filter(filter_long_and_short_reads, !grepl(' ', accession))
  
  to_be_blasted_entries <- get_taxonomizer_from_accession(bla, accessionTaxa)
  to_be_blasted_entries <- to_be_blasted_entries %>% arrange(species) %>%
    arrange(genus) %>% arrange(family)  %>% arrange(order) %>%
    arrange(class) %>% arrange(phylum) %>% arrange(superkingdom)
  
  
  
  out <- paste0(file_out_dir, Metabarcode_name, "/") 
  
  #Make the directory to put everything in
  Metabarcode_name = Metabarcode_name
  dir.create(file.path(paste0(file_out_dir, Metabarcode_name)))
  
  # save output
  save_output_as_csv(to_be_blasted_entries, "_primerTree_output_with_taxonomy", out, Metabarcode_name)
  make_hist_save_pdf(primer_search_blast_out$product_length, "_pre_filter_product_lengths_of_primerTree_output",  out, Metabarcode_name)
  save_output_as_csv(primer_search_blast_out, "_raw_primerTree_output", out, Metabarcode_name)
  make_hist_save_pdf(bla$product_length, "_post_filter_product_lengths_of_primerTree_output",  out, Metabarcode_name)
  
  #return if you're supposed to
  if(return_table) {
    return(to_be_blasted_entries)
  }
  else {
    return(NULL)
  }
}

accession_taxa_path <- "/data/home/galoscarleo/taxonomy/accessionTaxa.sql"
blast_seeds_parent <- "/data/home/galoscarleo/emily_test_output"
testCO1 <- RCRUX.dev::get_blast_seeds("GGWACWGGWTGAACWGTWTAYCCYCC",
                          "TANACYTCnGGRTGNCCRAARAAYCA",
                          blast_seeds_parent, "CO1_063022", accession_taxa_path,
                          num_permutations = 20, hitsize = "1000000",
                          evalue = "100000", word_size = "6",
                          MAX_TARGET_PER_TEMPLATE = "5",
                          NUM_TARGETS_WITH_PRIMERS = "500000",
                          organism = c("33208"), return_table = FALSE)