#!/usr/bin/env nextflow

/*
========================================================================================
=                                 h3achipimputation                                    =
========================================================================================
 h3achipimputation imputation pipeline.
----------------------------------------------------------------------------------------
 @Authors

----------------------------------------------------------------------------------------
 @Homepage / @Documentation
  https://github.com/h3abionet/chipimputation
----------------------------------------------------------------------------------------

----------------------------------------------------------------------------------------

================================================================================
=                           C O N F I G U R A T I O N                          =
================================================================================
*/

// Show help message
if (params.help){
    helpMessage()
    exit 0
}

// Configurable variables
params.name = false
params.email = false
params.plaintext_email = false

output_docs = file("$baseDir/docs/output.md")

// Has the run name been specified by the user?
// this has the bonus effect of catching both -name and --name
custom_runName = params.name
if( !(workflow.runName ==~ /[a-z]+_[a-z]+/) ){
    custom_runName = workflow.runName
}

// check if study genotype files exist
target_datasets = []
if(params.target_datasets) {
    params.target_datasets.each { target ->
        if (!file(target.value).exists() && !file(target.value).isFile()) exit 1, "Target VCF file ${target.value} not found. Please check your config file."
        target_datasets << [target.key, file(target.value)]
    }
}

// Validate eagle map file for phasing step and create channel if file exists
if(params.eagle_genetic_map) {
    if (!file(params.eagle_genetic_map).exists() && !file(params.eagle_genetic_map).isFile()) {
        System.err.println "MAP file ${params.eagle_genetic_map} not found. Please check your config file."
        exit 1
    }
}



// Validate reference genome
if(params.reference_genome) {
    if ((!file(params.reference_genome).exists() && !file(params.reference_genome).isFile()) || (!file("${params.reference_genome}.fai").exists())) {
        System.err.println "Reference genome file ${params.reference_genome} not found. Please check your config file."
        exit 1
    }
}

// Create channel for the study data from VCF files
Channel
        .from(target_datasets)
        .set{ target_datasets }


// Header log info
log.info """
=======================================================

h3achipimputation v${params.version}"

======================================================="""
def summary = [:]
summary['Pipeline Name']    = 'h3achipimputation'
summary['Pipeline Version'] = params.version
summary['Run Name']         = custom_runName ?: workflow.runName
summary['Target datasets']  = params.target_datasets.values().join(', ')
summary['Reference panels']  = params.ref_panels.keySet().join(', ')
summary['Max Memory']       = params.max_memory
summary['Max CPUs']         = params.max_cpus
summary['Max Time']         = params.max_time
summary['Output dir']       = params.outDir
summary['Working dir']      = workflow.workDir
summary['Current path']     = "$PWD"
summary['Container Engine'] = workflow.containerEngine
summary['Git info']         = "${workflow.repository} - ${workflow.revision} [${workflow.commitId}]"
summary['Command line']     = workflow.commandLine
if(workflow.containerEngine) {
    summary['Container'] = workflow.container
    summary['Current home'] = "$HOME"
    summary['Current user'] = "$USER"
    summary['Current path'] = "$PWD"
    summary['Working dir'] = workflow.workDir
    summary['Output dir'] = params.outDir
    summary['Script dir'] = workflow.projectDir
    summary['Config Profile'] = workflow.profile
}

if(params.email) summary['E-mail Address'] = params.email
log.info summary.collect { k,v -> "${k.padRight(15)}: $v" }.join("\n")
log.info "========================================="


def create_workflow_summary(summary) {

    def yaml_file = workDir.resolve('workflow_summary_mqc.yaml')
    yaml_file.text  = """
    id: 'h3achipimputation-summary'
    description: " - this information is collected when the pipeline is started."
    section_name: 'h3achipimputation Workflow Summary'
    section_href: 'https://github.com/h3abionet/chipimputation'
    plot_type: 'html'
    data: |
        <dl class=\"dl-horizontal\">
${summary.collect { k,v -> "            <dt>$k</dt><dd><samp>${v ?: '<span style=\"color:#999999;\">N/A</a>'}</samp></dd>" }.join("\n")}
        </dl>
    """.stripIndent()

    return yaml_file
}


/*
 * STEP 1: Parse software version numbers
 */
//process get_software_versions {
//    tag "get_software_versions"
//    output:
//        file("software_versions_mqc.yaml") into software_versions_yaml
//    script:
//        """
//        echo $params.version > v_pipeline.txt
//        echo $workflow.nextflow.version > v_nextflow.txt
//        minimac4 --version > v_minimac4.txt
//        eagle --version > v_eagle.txt
//        bcftools --version > v_bcftools.txt
//        ${params.plink} --version > v_${params.plink}.txt
//        scrape_software_versions.py > software_versions_mqc.yaml
//        """
//}


/*
 * STEP 2 - Check user's provided chromosomes vs those in map file
 */
target_datasets.into{ target_datasets; target_datasets_check }
process check_chromosome {
    tag "check_chromosome_${target_name}"
    input:
        set target_name, file(target_vcfFile) from target_datasets_check
    output:
        set target_name, file(chromFile) into check_chromosome
        set target_name, file(target_vcfFile), file(mapFile) into mapFile_cha
    script:
        base = file(target_vcfFile.baseName).baseName
        chromFile = "${base}_chromosomes.txt"
        mapFile = "${base}.map"
        """
        zcat ${target_vcfFile} | grep -v "^#" | awk -F' ' '{print \$1}' | sort -n | uniq >  ${chromFile}
        zcat ${target_vcfFile} | grep -v "^#" | awk -F' ' '{print \$1"\t"\$2"\t"\$3"\t"\$4"\t"\$5}' | sort -n | uniq > ${mapFile}
        """
}

// Check if specified chromosomes exist in VCF file
check_chromosome.into{ check_chromosome; check_chromosome1 }
chromosomes_ = [:]
chromosomes_['ALL'] = []
valid_chrms = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22]
not_chrs = []
in_chrs = []
notValid_chrs = []
check_chromosome1.toSortedList().val.each{ target_name, check_file ->
    chromosomes_[target_name] = file(check_file).readLines().unique().collect { it as int }.sort()
    chromosomes_[target_name].each { chrm ->
        if(!(chrm in chromosomes_['ALL'])) {
            if (chrm.toInteger() in valid_chrms){
                chromosomes_['ALL'] << chrm.toInteger()
            }
            else{
                notValid_chrs << chrm.toInteger()
            }
        }
    }
}
if (params.chromosomes == '' || params.chromosomes == 'ALL'){
    chromosomes = chromosomes_['ALL']
}
else{
    params.chromosomes.split(',').each { chrm ->
        chrm = chrm.toInteger()
        if (!(chrm in chromosomes_['ALL'])){
            not_chrs << chrm
        }
        else{
            in_chrs << chrm
        }
    }
    if (in_chrs.isEmpty()){
        System.err.println "|-- ERROR- No Chromosome(s) found not in target(s) dataset(s)! The pipeline will exit."
        exit 1
    }

    if (!(not_chrs.isEmpty())){
        System.err.println "|-- WARN- Chromosome(s) ${not_chrs.join(', ')} not in target datasets and will be ignored."
    }
    chromosomes = in_chrs

}
// Ignore invalid chromosome in VCF
if (!(notValid_chrs.isEmpty())){
    System.err.println "|-- ERROR- Chromosome(s) ${notValid_chrs.join(', ')} not valid chromosomes. Check your VCF file and remove invalid chromosomes! The pipeline will exit."
    exit 1
}
ignore_chrms = [:]
toImpute_chrms = [:]
mapFile_cha.into{ mapFile_cha; mapFile_cha_1}
mapFile_cha_1.toSortedList().val.each { target_name, target_vcfFile, mapFile ->
    chromosomes_[target_name].each{ chrm ->
        chrm = chrm.toInteger()
        if(!(chrm in chromosomes)){
            if(!(target_name in ignore_chrms)){
                ignore_chrms[target_name] = []
            }
            ignore_chrms[target_name] << chrm
        }
        else{
            if(!(target_name in toImpute_chrms)){
                toImpute_chrms[target_name] = []
            }
            toImpute_chrms[target_name] << chrm
        }
    }
}
targets_toImpute = Channel.create()
mapFile_cha.into{ mapFile_cha; mapFile_cha_2}
mapFile_cha_2.toSortedList().val.each { target_name, target_vcfFile, mapFile ->
    if(target_name in toImpute_chrms){
        targets_toImpute << [ target_name, target_vcfFile, mapFile, file(params.reference_genome) ]
    }
    else{
        System.err.println "|-- WARN- Dataset ${target_name} does not contain the specified chromosome(s) ${chromosomes.join(', ')} and will be ignored."
    }
}
targets_toImpute.close()
println "|-- Chromosomes used: ${chromosomes.join(', ')}"
if(params.chunk){
        println "|-- Chunks to impute: ${(params.chunk.split(',')).join(', ')}"
}

// check if ref files exist
params.ref_panels.each { ref ->
    chromosomes.each { chrm ->
        m3vcf = sprintf(params.ref_panels[ref.key].m3vcfFile, chrm)
        vcf = sprintf(params.ref_panels[ref.key].vcfFile, chrm)
        if(!file(m3vcf).exists()) exit 1, "File ${m3vcf} not found. Please check your config file."
        if(!file(vcf).exists()) exit 1, "File ${vcf} not found. Please check your config file."
    }
}

/*
 * STEP 3: QC
*/
targets_toImpute.into{ targets_toImpute; targets_toImpute_qc }
process check_mismatch {
    tag "check_mismatch_${target_name}_${chrms[0]}_${chrms[-1]}"
    label "medium"
    input:
        set target_name, file(target_vcfFile), file(mapFile), file(reference_genome) from targets_toImpute_qc
    output:
        set target_name, file(target_vcfFile), file(mapFile), file("${base}_checkRef_warn.log"), file("${base}_checkRef_summary.log") into check_mismatch
    script:
        base = file(target_vcfFile.baseName).baseName
        chrms = toImpute_chrms[target_name]
        """
        samtools faidx ${reference_genome}
        nblines=\$(zcat ${target_vcfFile} | wc -l)
        if (( \$nblines > 1 ))
        then
            bcftools norm --check-ref w \
                -f ${reference_genome} \
                ${target_vcfFile} \
                -Oz -o /dev/null
            cp .command.err ${base}_checkRef_warn.log
            bcftools +fixref \
                ${target_vcfFile} \
                -- \
                -f ${reference_genome} \
                2>&1 | tee "${base}_checkRef_summary.log"
            rm -f ${base}_clean_mind.*
        fi
        """
}

check_mismatch.into{ check_mismatch; check_mismatch_1 }
check_mismatch_noMis = Channel.create()
check_mismatch_1.toSortedList().val.each{ target_name, target_vcfFile, mapFile, warn, sumary ->
    mismatch = 0
    // TODO use summary instead, print mismatch, non-biallelic, non-ACGT
    file(warn).readLines().each{ it ->
        if(it.contains("REF_MISMATCH")){
            mismatch += 1
        }
    }
    if ( mismatch != 0 ) {
        System.err.println "|-- ${mismatch} ref mismatch sites found in '${target_name}' dataset! The pipeline will exit."
        exit 1
    }
    else{
        check_mismatch_noMis << [ target_name, target_vcfFile, mapFile, warn, sumary, toImpute_chrms[target_name]]
    }
}
check_mismatch_noMis.close()

/*
 * STEP 4 - Identify chromosomes and start/stop positions per chromosome and generate chunks
*/
check_mismatch_noMis.into{ check_mismatch_noMis; check_mismatch_noMis_2 }
process generate_chunks {
    tag "generate_chunks_${target_name}_${chrms[0]}_${chrms[-1]}"
    publishDir "${params.outDir}/Reports/${target_name}", overwrite: true, mode:'copy'
    label "small"
    input:
        set target_name, file(target_vcfFile), file(mapFile), file(mismatch_warn), file(mismatch_summary), chrms from check_mismatch_noMis_2
    output:
        set target_name, file(chunkFile) into generate_chunks
    script:
        if(params.chunk){chunk = params.chunk} else{chunk=''}
        chromosomes = chrms.join(',')
        chunkFile = "chunks.txt"
        chunk_size = params.chunk_size
        template "generate_chunks.py"
}


/*
 * STEP 5: QC
*/
check_mismatch_noMis.into{ check_mismatch_noMis; check_mismatch_noMis_1 }
process target_qc {
    tag "target_qc_${target_name}_${chrms[0]}_${chrms[-1]}"
    label "medium"
    input:
        set target_name, file(target_vcfFile), file(mapFile), file(mismatch_warn), file(mismatch_summary), chrms from check_mismatch_noMis_1
    output:
        set target_name, file("${base}_clean.vcf.gz") into target_qc
    script:
        base = file(target_vcfFile.baseName).baseName
        """
        bcftools view \
            -i 'ALT="."' ${target_vcfFile} | \
        bcftools query \
            -f '%CHROM  %POS  %REF  %ALT\\n' \
            > ${base}_noALT.snp
        bcftools view \
            -e 'ALT="."' ${target_vcfFile} \
            -Oz -o ${base}_noALT.vcf.gz
        bcftools norm \
            --rm-dup both \
            ${base}_noALT.vcf.gz \
            -Oz -o ${base}_clean.vcf.gz
        """
}


"""
Split VCF per chromosomes
"""
target_qc.into{ target_qc; target_qc_1 }
generate_chunks.into{ generate_chunks; generate_chunks_1 }
all_chunks = generate_chunks_1.toSortedList().val
all_chunks.each{ target_name_, chunk_file ->
    chunks = file(chunk_file).text.split()
    if(chunks.size() == 0){
        System.err.println "|-- ERROR- No valid chunks (${(params.chunk.split(',')).join(', ')}) in not specified chromosomes (${chromosomes.join(', ')}). Check your VCF file and correct your chunks for specified chromosomes! The pipeline will exit."
        exit 1
    }
}

def transform_chunk = { target_name, target_vcfFile ->
    chunks_datas = []
    all_chunks.each{ target_name_, chunk_file ->
        chunks = file(chunk_file).text.split()
        chunks.each{ chunk_data ->
            data = chunk_data.split(',')
            chrm = data[0]
            chunk_start = data[1]
            chunk_end = data[2]
            if (target_name == target_name_) {
                chunks_datas << [chrm, chunk_start, chunk_end, target_name, file(target_vcfFile)]
            }
        }
    }
    return chunks_datas
}
target_qc_chunk = target_qc_1
        .flatMap{ it -> transform_chunk(it) }


/*
 * STEP 6:
*/
process split_target_to_chunk {
    tag "split_${target_name}_${chrm}:${chunk_start}-${chunk_end}"
    label "medium"
    input:
        set chrm, chunk_start, chunk_end, target_name, file(target_vcfFile) from target_qc_chunk
    output:
        set chrm, chunk_start, chunk_end, target_name, file(target_vcfFile_chunk) into split_vcf_to_chrm
    script:
        base = file(target_vcfFile.baseName).baseName
        target_vcfFile_chunk = "${base}.chr${chrm}_${chunk_start}-${chunk_end}.vcf.gz"
        start = chunk_start - params.buffer_size
        if(chunk_start.toInteger() - params.buffer_size.toInteger() <= 0){ end = 1 }
        end = chunk_end.toInteger() + params.buffer_size.toInteger()
        """
        bcftools index --tbi -f ${target_vcfFile}
        bcftools view \
            --regions ${chrm}:${start}-${end} \
            -m2 -M2 -v snps \
            ${target_vcfFile} \
            -Oz -o ${target_vcfFile_chunk}
        """
}

split_vcf_to_chrm.into{ split_vcf_to_chrm; split_vcf_to_chrm_1 }
def transform_qc_chunk = { chrm, chunk_start, chunk_end, target_name, target_vcfFile ->
    chunks_datas = []
    params.ref_panels.each { ref ->
        ref_m3vcf = sprintf(params.ref_panels[ref.key].m3vcfFile, chrm)
        ref_vcf = sprintf(params.ref_panels[ref.key].vcfFile, chrm)
        chunks_datas << [chrm, chunk_start, chunk_end, target_name, file(target_vcfFile), ref.key, file(ref_vcf), file(ref_m3vcf), file(params.eagle_genetic_map)]
    }
    return chunks_datas
}

target_qc_chunk_ref = split_vcf_to_chrm_1
        .flatMap{ it -> transform_qc_chunk(it) }


/*
 * STEP 7: Phase each chunk using eagle
*/
split_vcf_to_chrm.into{ split_vcf_to_chrm; split_vcf_to_chrm_1 }
process phase_target_chunk {
    tag "phase_${target_name}_${chrm}:${chunk_start}-${chunk_end}_${ref_name}"
    label "bigmem"
    input:
        set chrm, chunk_start, chunk_end, target_name, file(target_vcfFile_chunk), ref_name, file(ref_vcf), file(ref_m3vcf), file(eagle_genetic_map) from target_qc_chunk_ref
    output:
        set chrm, chunk_start, chunk_end, target_name, file("${file_out}.vcf.gz"), ref_name, file(ref_vcf), file(ref_m3vcf) into phase_target
    script:
        file_out = "${file(target_vcfFile_chunk.baseName).baseName}_${ref_name}-phased"
        """
        nblines=\$(zcat ${target_vcfFile_chunk} | grep -v '^#' | wc -l)
        if (( \$nblines > 0 ))
        then
            bcftools index --tbi -f ${ref_vcf}
            bcftools index --tbi -f ${target_vcfFile_chunk}
            eagle \
                --vcfTarget=${target_vcfFile_chunk} \
                --geneticMapFile=${eagle_genetic_map} \
                --vcfRef=${ref_vcf} \
                --vcfOutFormat=z \
                --noImpMissing \
                --chrom=${chrm} \
                --bpStart=${chunk_start} \
                --bpEnd=${chunk_end} \
                --bpFlanking=${params.buffer_size} \
                --outPrefix=${file_out} 2>&1 | tee ${file_out}.log
            if [ ! -f "${file_out}.vcf.gz" ]; then
                touch ${file_out}.vcf && bgzip -f ${file_out}.vcf
            fi
        else
            touch ${file_out}.vcf && bgzip -f ${file_out}.vcf
        fi
        """
}


/*
 * STEP 8:
*/
process impute_target {
    tag "imp_${target_name}_${chrm}:${chunk_start}-${chunk_end}_${ref_name}"
    publishDir "${params.outDir}/impute/${ref_name}/${target_name}/${chrm}", overwrite: true, mode:'symlink'
    publishDir "${params.outDir}/impute/${target_name}/${ref_name}/${chrm}", overwrite: true, mode:'symlink'
    label "bigmem"
    input:
        set chrm, chunk_start, chunk_end, target_name, file(target_phased_vcfFile), ref_name, file(ref_vcf), file(ref_m3vcf) from phase_target
    output:
        set chrm, chunk_start, chunk_end, target_name, ref_name, file("${base}_imputed.dose.vcf.gz"), file("${base}_imputed.info") into impute_target
    shell:
        base = "${file(target_phased_vcfFile.baseName).baseName}"
        """
        nblines=\$(zcat ${target_phased_vcfFile} | grep -v '^#' | wc -l)
        if (( \$nblines > 0 ))
        then
            minimac4 \
                --refHaps ${ref_m3vcf} \
                --haps ${target_phased_vcfFile} \
                --format GT,DS \
                --allTypedSites \
                --minRatio ${params.minRatio} \
                --chr ${chrm} --start ${chunk_start} --end ${chunk_end} --window ${params.buffer_size} \
                --prefix ${base}_imputed
        else
             touch ${base}_imputed.dose.vcf && bgzip -f ${base}_imputed.dose.vcf
             touch ${base}_imputed.info
        fi
        """
}


'''
Combine output
'''
impute_target.into{impute_target; impute_target_1}

// Create a dataflow instance of all impute results
imputeCombine = [:]
infoCombine = [:]
infoCombine_all = [:]
impute_target_list = impute_target_1.toSortedList().val
impute_target_list.each{ chrm, chunk_start, chunk_end, target_name, ref_name, impute, info ->
    id = target_name +"__"+ ref_name +"__"+ chrm
    if(!(id in imputeCombine)){
        imputeCombine[id] = [target_name, ref_name, chrm, []]
    }
    imputeCombine[id][3] << impute
    if(!(id in infoCombine)){
        infoCombine[id] = [target_name, ref_name, chrm, []]
    }
    infoCombine[id][3] << info
    id1 = target_name +"__"+ ref_name
    if(!(id1 in infoCombine_all)){
        infoCombine_all[id1] = [target_name, ref_name, []]
    }
    infoCombine_all[id1][2] << info
}


"""
Combine impute chunks to chromosomes
"""
process combineImpute {
    //maxForks 1 // TODO: this is only because bcftools sort is using a common TMPFOLDER
    tag "impComb_${target_name}_${ref_name}_${chrm}"
    publishDir "${params.outDir}/impute/combined/${target_name}/${ref_name}", overwrite: true, mode:'symlink'
//    publishDir "${params.outDir}/impute/combined/${ref_name}/${target_name}", overwrite: true, mode:'symlink'
    label "bigmem"
    input:
        set target_name, ref_name, chrm, file(imputed_files) from imputeCombine.values()
    output:
        set target_name, ref_name, chrm, file(comb_impute) into combineImpute
    script:
        comb_impute = "${target_name}_${ref_name}_chr${chrm}.imputed.gz"
        """
        bcftools concat \
            ${imputed_files} \
            -Oz -o ${target_name}.tmp.vcf.gz
        ## Recalculate AC, AN, AF
        bcftools +fill-tags ${target_name}.tmp.vcf.gz -Oz -o ${target_name}.tmp1.vcf.gz
        bcftools sort ${target_name}.tmp1.vcf.gz -T . -Oz -o ${comb_impute}
        rm ${target_name}.tmp*.vcf.gz
        """
}


"""
Combine impute info chunks to chromosomes
"""
process combineInfo {
    tag "infoComb_${target_name}_${ref_name}_${chrm}"
    publishDir "${params.outDir}/impute/combined/${target_name}/${ref_name}", overwrite: true, mode:'symlink'
//    publishDir "${params.outDir}/impute/combined/${ref_name}/${target_name}", overwrite: true, mode:'symlink'
    label "medium"
    input:
        set target_name, ref_name, chrm, file(info_files) from infoCombine.values()
    output:
        set target_name, ref_name, chrm, file(comb_info) into combineInfo
    script:
        comb_info = "${target_name}_${ref_name}_chr${chrm}.imputed_info"
        """
        head -n1 ${info_files[0]} > ${comb_info}
        tail -q -n +2 ${info_files.join(' ')} >> ${comb_info}
        """
}


"""
Combine all impute info chunks by dataset
"""
process combineInfo_all {
    tag "infoComb_${target_name}_${ref_name}_${chrms}"
    publishDir "${params.outDir}/impute/combined/${target_name}/${ref_name}", overwrite: true, mode:'symlink'
    label "medium"
    input:
        set target_name, ref_name, file(info_files) from infoCombine_all.values()
    output:
        set target_name, ref_name, file(comb_info) into combineInfo_all
    script:
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        comb_info = "${target_name}_${ref_name}_chrs${chrms}.imputed_info"
        """
        head -n1 ${info_files[0]} > ${comb_info}
        tail -q -n +2 ${info_files.join(' ')} >> ${comb_info}
        """
}


"""
Generating report
"""
combineInfo_all.into { combineInfo_all; combineInfo_all_1 }
combineInfo_all_list = combineInfo_all_1.toSortedList().val
target_infos = [:]
ref_infos = [:]
ref_panels = params.ref_panels.keySet().join('_')
target_names = params.target_datasets.keySet().join('_')
combineInfo_all_list.each{ target_name, ref_name, comb_info ->
    if(!(target_name in target_infos)){
        target_infos[target_name] = [ target_name, ref_name, []]
    }
    target_infos[target_name][2] << ref_name+"=="+comb_info
    if(!(ref_name in ref_infos)){
        ref_infos[ref_name] = [ ref_name, target_name, []]
    }
    ref_infos[ref_name][2] << target_name+"=="+comb_info
}


"""
Filtering all reference panels by maf for a dataset
"""
process filter_info_target {
    tag "filter_${target_name}_${ref_panels}_${chrms}"
    publishDir "${params.outDir}/impute/combined/${target_name}", overwrite: true, mode:'symlink'
    label "medium"
    input:
        set target_name, ref_name, infos from target_infos.values()
    output:
        set target_name, ref_panels, file(well_out) into target_info_Well
        set target_name, ref_panels, file(acc_out) into target_info_Acc
    script:
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        comb_info = "${target_name}_${ref_panels}_${chrms}.imputed_info"
        well_out = "${comb_info}_well_imputed"
        acc_out = "${comb_info}_accuracy"
        infos = infos.join(',')
        impute_info_cutoff = params.impute_info_cutoff
        template "filter_info_minimac.py"
}


"""
Report 1: Well imputed all reference panels by maf for a dataset
"""
target_info_Well.into{ target_info_Well; target_info_Well_1}
process report_well_imputed_target {
    tag "report_wellImputed_${target_name}_${ref_panels}_${chrms}"
    publishDir "${params.outDir}/Reports/${target_name}", overwrite: true, mode:'copy'
    label "medium"
    input:
        set target_name, ref_panels, file(inWell_imputed) from target_info_Well_1
    output:
        set target_name, ref_panels, file(outWell_imputed), file("${outWell_imputed}_summary.tsv") into report_well_imputed_target
    script:
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        outWell_imputed = "${target_name}_${ref_panels}_${chrms}.imputed_info_report_well_imputed.tsv"
        group = "REF_PANEL"
        template "report_well_imputed.py"
}


"""
Plot performance all reference panels by maf for a dataset
"""
report_well_imputed_target.into{ report_well_imputed_target; report_well_imputed_target_1 }
process plot_performance_target{
    tag "plot_performance_dataset_${target_name}_${ref_panels}_${chrms}"
    publishDir "${params.outDir}/Reports/${target_name}/plots", overwrite: true, mode:'copy'
    input:
        set target_name, ref_panels, file(well_imputed_report), file(well_imputed_report_summary) from report_well_imputed_target_1
    output:
        set target_name, ref_panels, file(plot_by_maf) into plot_performance_target
    script:
        plot_by_maf = "${well_imputed_report.baseName}_performance_by_maf.tiff"
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        report = well_imputed_report
        group = "REF_PANEL"
        xlab = "MAF bins"
        ylab = "Number of well imputed SNPs"
        template "plot_results_by_maf.R"
}


"""
Filtering all targets by maf for a reference panel
"""
process filter_info_ref {
    tag "filter_${ref_name}_${target_names}_${chrms}"
    publishDir "${params.outDir}/impute/combined/${ref_name}", overwrite: true, mode:'symlink'
    label "medium"
    input:
        set ref_name, target_names, infos from ref_infos.values()
    output:
        set ref_name, target_names, file(well_out) into ref_info_Well
        set ref_name, target_names, file(acc_out) into ref_info_Acc
    script:
        chrms = chromosomes[0]+"-"+chromosomes[-1]
        comb_info = "${ref_name}_${target_names}_${chrms}.imputed_info"
        well_out = "${comb_info}_well_imputed"
        acc_out = "${comb_info}_accuracy"
        infos = infos.join(',')
        impute_info_cutoff = params.impute_info_cutoff
        template "filter_info_minimac.py"
}


"""
Report: Well imputed all targets by maf for a reference panel
"""
ref_info_Well.into{ ref_info_Well; ref_info_Well_1}
process report_well_imputed_ref {
    tag "report_wellImputed_${ref_name}_${target_names}_${chrms}"
    publishDir "${params.outDir}/Reports/${ref_name}", overwrite: true, mode:'copy'
    label "medium"
    input:
        set ref_name, target_names, file(inWell_imputed) from ref_info_Well_1
    output:
        set ref_name, target_names, file(outWell_imputed), file("${outWell_imputed}_summary.tsv") into report_well_imputed_ref
    script:
        chrms = chromosomes[0]+"-"+chromosomes[-1]
        outWell_imputed = "${ref_name}_${target_names}_${chrms}.imputed_info_report_well_imputed.tsv"
        group = "DATASET"
        template "report_well_imputed.py"
}


"""
Plot performance all targets by maf for a reference panel
"""
report_well_imputed_ref.into{ report_well_imputed_ref; report_well_imputed_ref_1 }
process plot_performance_ref{
    tag "plot_performance_dataset_${ref_name}_${target_names}_${chrms}"
    publishDir "${params.outDir}/Reports/${ref_name}/plots", overwrite: true, mode:'copy'
    input:
        set ref_name, target_names, file(well_imputed_report), file(well_imputed_report_summary) from report_well_imputed_ref_1
    output:
        set ref_name, target_names, file(plot_by_maf) into plot_performance_ref
    script:
        plot_by_maf = "${well_imputed_report.baseName}_performance_by_maf.tiff"
        chrms = chromosomes[0]+"-"+chromosomes[-1]
        report = well_imputed_report
        group = "DATASET"
        xlab = "MAF bins"
        ylab = "Number of well imputed SNPs"
        template "plot_results_by_maf.R"
}


"""
Repor 2: Accuracy all reference panels by maf for a dataset
"""
target_info_Acc.into{ target_info_Acc; target_info_Acc_2}
process report_accuracy_target {
    tag "report_acc_${target_name}_${ref_panels}_${chrms}"
    publishDir "${params.outDir}/Reports/${target_name}", overwrite: true, mode:'copy'
//    publishDir "${params.outDir}/Reports/${ref_name}/${target_name}", overwrite: true, mode:'copy'
    label "medium"
    input:
        set target_name, ref_panels, file(inSNP_acc) from target_info_Acc_2
    output:
        set target_name, ref_panels, file(outSNP_acc) into report_SNP_acc_target
    script:
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        outSNP_acc = "${target_name}_${ref_panels}_${chrms}.imputed_info_report_accuracy.tsv"
        group = "REF_PANEL"
        template "report_accuracy_by_maf.py"
}


"""
Plot accuracy all reference panels by maf for a dataset
"""
report_SNP_acc_target.into{ report_SNP_acc_target; report_SNP_acc_target_1 }
process plot_accuracy_target{
    tag "plot_accuracy_dataset_${target_name}_${ref_panels}_${chrms}"
    publishDir "${params.outDir}/Reports/${target_name}/plots", overwrite: true, mode:'copy'
    input:
        set target_name, ref_panels, file(accuracy_report) from report_SNP_acc_target_1
    output:
        set target_name, ref_panels, file(plot_by_maf) into plot_accuracy_target
    script:
        plot_by_maf = "${accuracy_report.baseName}_accuracy_by_maf.tiff"
        chrms = chromosomes_[target_name][0]+"-"+chromosomes_[target_name][-1]
        report = accuracy_report
        group = "REF_PANEL"
        xlab = "MAF bins"
        ylab = "Concordance rate"
        template "plot_results_by_maf.R"
}

def helpMessage() {
    log.info"""
    =========================================
    h3achipimputation v${params.version}
    =========================================
    Usage:

    The typical command for running the pipeline is as follows:

    nextflow run h3abionet/chipimputation --reads '*_R{1,2}.fastq.gz' -profile standard,docker

    Mandatory arguments (Must be specified in the configuration file, and must be surrounded with quotes):
      --target_datasets             Path to input study data (Can be one ou multiple for multiple runs)
      --genome                      Human reference genome for checking REF mismatch
      --ref_panels                  Reference panels to impute to (Can be one ou multiple for multiple runs)
      -profile                      Configuration profile to use. Can use multiple (comma separated)
                                    Available: standard, conda, docker, singularity, test

    Other options:
      --outDir                      The output directory where the results will be saved
      --email                       Set this parameter to your e-mail address to get a summary e-mail with details of the run sent to you when the workflow exits
      --name                        Name for the pipeline run. If not specified, Nextflow will automatically generate a random mnemonic.
      --project_name                Project name. If not specified, target file name will be used as project name
    """.stripIndent()
}
