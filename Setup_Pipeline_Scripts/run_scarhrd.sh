#!/bin/bash

#Executable file: chmod +x run_scarhrd.sh
#Run with arguments
#./run_scarhrd.sh -i ./Output_seqz -o ./ScarHRD_Results -r grch37

#Values
ref_genome="grch37"
output_dir=""
input_dir=""

#Function to display help message
usage() {
    echo "Usage: $0 -i <input_dir> -o <output_dir> [-r <reference_genome>]"
    echo ""
    echo "Arguments:"
    echo " -i Path to directory containing .seq.gz files (Required)"
    echo " -o Path to output directory for results (Required)"
    echo " -r Reference genome (default:grch37)"
    echo " -h Show this help message"
    exit 1
}

#Parse command line arguments
while getopts "i:o:r:h" opt; do
    case ${opt} in
        i) input_dir=${OPTARG} ;;
        o) output_dir=${OPTARG} ;;
        r) ref_genome=${OPTARG} ;;
        h) usage ;;
        *) usage ;;
    esac
done

#while do done: while-condition to start, do-start, done-finish
#getopts: built-in tool to parse flags
#: indicates that this flag expects a value e..g, i:, o:
#h is just a switch which turns on help
#opt: variable that holds the current flag being processed
#case: a switch statement that checks which flag is currently inside opt (i, o, r). esac indicates decision block ends here
#OPTARG -> filled by getopts, holding the value provided after the flag
#different flag e.g., -x given then it catches and shows the usage menu

#Validate required arguments
#If Input or Output flag is not given in argument
if [ -z "$input_dir" ] || [ -z "$output_dir" ]; then
    echo "Error: Input (-i) and Output (-o) directories are required"
    usage
fi 

#fi terminates if else
#[]: test command
#$ fetches the value of that variable
#-z: Checks if a string is empty (0 length)
#||: Logical OR

#Convert to absolute paths to avoid Docker mounting issues due to relative paths (. or ./data). Docker requires absolute paths for volume mounting (-v)
input_dir=$(realpath "$input_dir")
output_dir=$(realpath "$output_dir")
#realpath converts relative path (. or ./data) to absolute paths (/home/user/project/data)

if [ ! -d "$output_dir" ]; then
    echo "Creating output directory: $output_dir"
    mkdir -p "$output_dir"
fi

#-d: Checks if a directory exists
#!: logical NOT
#mkdir -p: Creates the directory. The -p (parents) flag ensures it creates any missing parent folders and doesn't crash if the folder already exists

echo "==============="
echo "Starting scarHRD Pipeline"
echo "Input Dir:  $input_dir"
echo "Output Dir: $output_dir"
echo "Ref Genome: $ref_genome"
echo "==============="

#Main Loop through seqz.gz files
count=0
#Recursive loop:
#1. 'find' seaches for all .seqz.gz files in input_dir and subfolders
#2. Feed that list into a while loop
while IFS= read -r file; do
    #Get the directory where this specific file lives
    file_dir=$(dirname "$file")

    #Get the filename (sample.seqz.gz)
    filename=$(basename "$file")
    echo "Processing: $filename"
    echo "Location:   $file_dir"

    #Run Docker container
    #1.Mount Input dir to /data
    #2.Run scar_score (R calculates score)
    #3.Note: scarHRD writes output to the input directory by default
    #docker run --rm: Starts a container and automatically removes it (--rm) when it finishes
    #-v "$input_dir":/data: Volume mapping explained to docker: takes input_dir folder from comp and plugs the input_dir into the container at the path /data
    #R -e: Runs R in "Expression" mode. It executes the code (scar_score) in quotes and then quits.
    #setwd: force R to walk into the specific room /data
    docker run --rm \
        -v "$file_dir":/data \
        hydragenetics/scarhrd:20200825 \
        R --vanilla -e "setwd('/data'); library(scarHRD); scar_score('$filename', reference='$ref_genome', seqz=TRUE)"
    
    #echo "Moving results for $filename to output directory"
    #mv "$file_dir"/*_HRD.txt "$output_dir"/ 2>/dev/null
    #mv "$file_dir"/*_HRDresults.txt "$output_dir"/ 2>/dev/null
    #mv "$file_dir"/*_info_seg.txt "$output_dir"/ 2>/dev/null

    count=$((count+1))
    echo "---------"
done < <(find "$input_dir" -name "*.seqz.gz")
#< <(...) = Redirection + Process Substitution
#<(find): Bash runs the find command inside the parentheses. It takes the output (the list of files) and pretends it is a temporary file
#<: It tells the while loop: "Don't read from the keyboard; read from this 'temporary file' created by the process substitution."

echo "Batch processing complete. Processed $count samples."
echo "Results valid in: $output_dir"
