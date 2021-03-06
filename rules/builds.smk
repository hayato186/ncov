rule download:
    message: "Downloading metadata and fasta files from S3"
    output:
        sequences = config["sequences"],
        metadata = config["metadata"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        aws s3 cp s3://nextstrain-ncov-private/metadata.tsv {output.metadata:q}
        aws s3 cp s3://nextstrain-ncov-private/sequences.fasta {output.sequences:q}
        """

rule filter:
    message:
        """
        Filtering to
          - excluding strains in {input.exclude}
          - minimum genome length of {params.min_length}
        """
    input:
        sequences = rules.download.output.sequences,
        metadata = rules.download.output.metadata,
        include = config["files"]["include"],
        exclude = config["files"]["exclude"]
    output:
        sequences = "results/filtered.fasta"
    params:
        min_length = config["filter"]["min_length"],
        exclude_where = config["filter"]["exclude_where"],
        group_by = config["filter"]["group_by"],
        sequences_per_group = config["filter"]["sequences_per_group"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur filter \
            --sequences {input.sequences} \
            --metadata {input.metadata} \
            --include {input.include} \
            --exclude {input.exclude} \
            --exclude-where {params.exclude_where}\
            --min-length {params.min_length} \
            --group-by {params.group_by} \
            --sequences-per-group {params.sequences_per_group} \
            --output {output.sequences}
        """

checkpoint partition_sequences:
    input:
        sequences = rules.filter.output.sequences
    output:
        split_sequences = directory("results/split_sequences/")
    params:
        sequences_per_group = config["partition_sequences"]["sequences_per_group"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/partition-sequences.py \
            --sequences {input.sequences} \
            --sequences-per-group {params.sequences_per_group} \
            --output-dir {output.split_sequences}
        """

rule align:
    message:
        """
        Aligning sequences to {input.reference}
          - gaps relative to reference are considered real
        Cluster:  {wildcards.cluster}
        """
    input:
        sequences = "results/split_sequences/{cluster}.fasta",
        reference = config["files"]["reference"]
    output:
        alignment = "results/split_alignments/{cluster}.fasta"
    benchmark:
        "benchmarks/align_{cluster}.txt"
    threads: 2
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur align \
            --sequences {input.sequences} \
            --reference-sequence {input.reference} \
            --output {output.alignment} \
            --nthreads {threads} \
            --remove-reference \
            --fill-gaps
        """

def _get_alignments(wildcards):
    checkpoint_output = checkpoints.partition_sequences.get(**wildcards).output[0]
    return expand("results/split_alignments/{i}.fasta",
                  i=glob_wildcards(os.path.join(checkpoint_output, "{i}.fasta")).i)

rule aggregate_alignments:
    message: "Collecting alignments"
    input:
        alignments = _get_alignments
    output:
        alignment = "results/aligned.fasta"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        cat {input.alignments} > {output.alignment}
        """

rule mask:
    message:
        """
        Mask bases in alignment
          - masking {params.mask_from_beginning} from beginning
          - masking {params.mask_from_end} from end
          - masking other sites: {params.mask_sites}
        """
    input:
        alignment = rules.aggregate_alignments.output.alignment
    output:
        alignment = "results/masked.fasta"
    params:
        mask_from_beginning = config["mask"]["mask_from_beginning"],
        mask_from_end = config["mask"]["mask_from_end"],
        mask_sites = config["mask"]["mask_sites"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/mask-alignment.py \
            --alignment {input.alignment} \
            --mask-from-beginning {params.mask_from_beginning} \
            --mask-from-end {params.mask_from_end} \
            --mask-sites {params.mask_sites} \
            --output {output.alignment}
        """

def get_priorities(w):
    if "priorities" in config["regions"][w.region][w.subsample] \
        and config["regions"][w.region][w.subsample]["priorities"]["type"]=="proximity":
        return f"{get_region_path(w)}proximity_{config['regions'][w.region][w.subsample]['priorities']['focus']}.tsv"
    else:
        # TODO: find a way to make the list of input files depend on config
        return config["files"]["include"]

def get_priority_argument(w):
    if "priorities" in config["regions"][w.region][w.subsample]\
        and config["regions"][w.region][w.subsample]["priorities"]["type"]=="proximity":
            return "--priority " + get_priorities(w)
    else:
        ""

rule subsample:
    message:
        """
        Subsample all sequences into a focal set for {wildcards.region} with {params.sequences_per_group} per region
        """
    input:
        sequences = rules.mask.output.alignment,
        metadata = rules.download.output.metadata,
        include = config["files"]["include"],
        priorities = get_priorities
    output:
        sequences = REGION_PATH + "sample-{subsample}.fasta"
    params:
        group_by = lambda w: config["regions"][w.region][w.subsample]["group_by"],
        sequences_per_group = lambda w: config["regions"][w.region][w.subsample]["seq_per_group"],
        exclude_argument = lambda w: config["regions"][w.region][w.subsample].get("exclude", ""),
        include_argument = lambda w: config["regions"][w.region][w.subsample].get("include", ""),
        priority_argument = get_priority_argument
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur filter \
            --sequences {input.sequences} \
            --metadata {input.metadata} \
            --include {input.include} \
            {params.exclude_argument} \
            {params.include_argument} \
            {params.priority_argument} \
            --group-by {params.group_by} \
            --sequences-per-group {params.sequences_per_group} \
            --output {output.sequences} \
        """

rule proximity_score:
    message:
        """
        determine priority for inclusion in as phylogenetic context by
        genetic similiarity to sequences in focal set for region '{wildcards.region}'.
        """
    input:
        alignment = rules.mask.output.alignment,
        metadata = rules.download.output.metadata,
        focal_alignment = REGION_PATH + "sample-{focus}.fasta"
    output:
        priorities = REGION_PATH + "proximity_{focus}.tsv"
    resources:
        mem_mb = 4000
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/priorities.py --alignment {input.alignment} \
            --metadata {input.metadata} \
            --focal-alignment {input.focal_alignment} \
            --output {output.priorities}
        """


rule subsample_regions:
    message:
        """
        Combine and deduplicate FASTAs
        """
    input:
        lambda w: [REGION_PATH + f"sample-{subsample}.fasta" for subsample in config["regions"][w.region]]
    output:
        alignment = REGION_PATH + "subsampled_alignment.fasta"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/combine-and-dedup-fastas.py \
            --input {input} \
            --output {output}
        """

rule adjust_metadata_regions:
    message:
        """
        Adjusting metadata for region '{wildcards.region}'
        """
    input:
        metadata = rules.download.output.metadata
    output:
        metadata = REGION_PATH + "metadata_adjusted.tsv"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/adjust_regional_meta.py \
            --region "{wildcards.region}" \
            --metadata {input.metadata} \
            --output {output.metadata}
        """

def _get_alignments_for_tree(wildcards):
    """Use all sequences for global builds. Use a specific subsampled set of
    sequences for regional builds.
    """
    if wildcards.region == "global":
        return rules.subsample_focus.output.sequences
    else:
        return rules.subsample_regions.output.alignment

rule tree:
    message: "Building tree"
    input:
        alignment = _get_alignments_for_tree
    output:
        tree = REGION_PATH + "tree_raw.nwk"
    benchmark:
        "benchmarks/tree_{region}.txt"
    threads: 4
    resources:
        # Multiple sequence alignments can use up to 40 times their disk size in
        # memory, especially for larger alignments.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 40 * int(input.size / 1024 / 1024)
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur tree \
            --alignment {input.alignment} \
            --output {output.tree} \
            --nthreads {threads}
        """

def _get_metadata_by_wildcards(wildcards):
    if wildcards.region in ["global", "swiss"]:
        return rules.download.output.metadata
    else:
        return rules.adjust_metadata_regions.output.metadata

rule refine:
    message:
        """
        Refining tree
          - estimate timetree
          - use {params.coalescent} coalescent timescale
          - estimate {params.date_inference} node dates
        """
    input:
        tree = rules.tree.output.tree,
        alignment = _get_alignments_for_tree,
        metadata = _get_metadata_by_wildcards
    output:
        tree = REGION_PATH + "tree.nwk",
        node_data = REGION_PATH + "branch_lengths.json"
    benchmark:
        "benchmarks/refine_{region}.txt"
    threads: 1
    resources:
        # Multiple sequence alignments can use up to 40 times their disk size in
        # memory, especially for larger alignments.
        # Note that Snakemake >5.10.0 supports input.size_mb to avoid converting from bytes to MB.
        mem_mb=lambda wildcards, input: 40 * int(input.size / 1024 / 1024)
    params:
        root = config["refine"]["root"],
        clock_rate = config["refine"]["clock_rate"],
        clock_std_dev = config["refine"]["clock_std_dev"],
        coalescent = config["refine"]["coalescent"],
        date_inference = config["refine"]["date_inference"],
        divergence_unit = config["refine"]["divergence_unit"],
        clock_filter_iqd = config["refine"]["clock_filter_iqd"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur refine \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --metadata {input.metadata} \
            --output-tree {output.tree} \
            --output-node-data {output.node_data} \
            --root {params.root} \
            --timetree \
            --clock-rate {params.clock_rate} \
            --clock-std-dev {params.clock_std_dev} \
            --coalescent {params.coalescent} \
            --date-inference {params.date_inference} \
            --divergence-unit {params.divergence_unit} \
            --date-confidence \
            --no-covariance \
            --clock-filter-iqd {params.clock_filter_iqd}
        """

rule ancestral:
    message:
        """
        Reconstructing ancestral sequences and mutations
          - inferring ambiguous mutations
        """
    input:
        tree = rules.refine.output.tree,
        alignment = rules.mask.output
    output:
        node_data = REGION_PATH + "nt_muts.json"
    params:
        inference = config["ancestral"]["inference"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur ancestral \
            --tree {input.tree} \
            --alignment {input.alignment} \
            --output-node-data {output.node_data} \
            --inference {params.inference} \
            --infer-ambiguous
        """

rule haplotype_status:
    message: "Annotating haplotype status relative to {params.reference_node_name}"
    input:
        nt_muts = rules.ancestral.output.node_data
    output:
        node_data = REGION_PATH + "haplotype_status.json"
    params:
        reference_node_name = config["reference_node_name"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/annotate-haplotype-status.py \
            --ancestral-sequences {input.nt_muts} \
            --reference-node-name {params.reference_node_name:q} \
            --output {output.node_data}
        """

rule translate:
    message: "Translating amino acid sequences"
    input:
        tree = rules.refine.output.tree,
        node_data = rules.ancestral.output.node_data,
        reference = config["files"]["reference"]
    output:
        node_data = REGION_PATH + "aa_muts.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur translate \
            --tree {input.tree} \
            --ancestral-sequences {input.node_data} \
            --reference-sequence {input.reference} \
            --output-node-data {output.node_data} \
        """

def _get_sampling_trait_for_wildcards(wildcards):
    mapping = {"north-america": "country", "oceania": "country"} # TODO: switch to "division"
    return mapping[wildcards.region] if wildcards.region in mapping else "country"

def _get_exposure_trait_for_wildcards(wildcards):
    mapping = {"north-america": "country_exposure", "oceania": "country_exposure"} # TODO: switch to "division_exposure"
    return mapping[wildcards.region] if wildcards.region in mapping else "country_exposure"

rule traits:
    message:
        """
        Inferring ancestral traits for {params.columns!s}
          - increase uncertainty of reconstruction by {params.sampling_bias_correction} to partially account for sampling bias
        """
    input:
        tree = rules.refine.output.tree,
        metadata = _get_metadata_by_wildcards
    output:
        node_data = REGION_PATH + "traits.json"
    params:
        columns = lambda w: config["traits"][w.region]["columns"],
        sampling_bias_correction = lambda w: config["traits"][w.region]["sampling_bias_correction"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur traits \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --output {output.node_data} \
            --columns {params.columns} \
            --confidence \
            --sampling-bias-correction {params.sampling_bias_correction} \
        """

rule clades:
    message: "Adding internal clade labels"
    input:
        tree = rules.refine.output.tree,
        aa_muts = rules.translate.output.node_data,
        nuc_muts = rules.ancestral.output.node_data,
        clades = config["files"]["clades"]
    output:
        clade_data = REGION_PATH + "clades.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur clades --tree {input.tree} \
            --mutations {input.nuc_muts} {input.aa_muts} \
            --clades {input.clades} \
            --output-node-data {output.clade_data}
        """

rule colors:
    message: "Constructing colors file"
    input:
        ordering = config["files"]["ordering"],
        color_schemes = config["files"]["color_schemes"],
        metadata = _get_metadata_by_wildcards
    output:
        colors = "config/colors_{region}.tsv"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/assign-colors.py \
            --ordering {input.ordering} \
            --color-schemes {input.color_schemes} \
            --output {output.colors} \
            --metadata {input.metadata}
        """

rule recency:
    message: "Use metadata on submission date to construct submission recency field"
    input:
        metadata = _get_metadata_by_wildcards
    output:
        node_data = REGION_PATH + "recency.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 scripts/construct-recency-from-submission-date.py \
            --metadata {input.metadata} \
            --output {output.node_data}
        """

rule tip_frequencies:
    message: "Estimating censored KDE frequencies for tips"
    input:
        tree = rules.refine.output.tree,
        metadata = _get_metadata_by_wildcards
    output:
        tip_frequencies_json = "auspice/ncov_{region}_tip-frequencies.json"
    params:
        min_date = config["frequencies"]["min_date"],
        pivot_interval = config["frequencies"]["pivot_interval"],
        narrow_bandwidth = config["frequencies"]["narrow_bandwidth"],
        proportion_wide = config["frequencies"]["proportion_wide"]
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur frequencies \
            --method kde \
            --metadata {input.metadata} \
            --tree {input.tree} \
            --min-date {params.min_date} \
            --pivot-interval {params.pivot_interval} \
            --narrow-bandwidth {params.narrow_bandwidth} \
            --proportion-wide {params.proportion_wide} \
            --output {output.tip_frequencies_json}
        """

def export_title(wildcards):
    region = wildcards.region

    if not region:
        return "Genomic epidemiology of novel coronavirus"
    elif region == "global":
        return "Genomic epidemiology of novel coronavirus - Global subsampling"
    else:
        region_title = region.replace("-", " ").title()
        return f"Genomic epidemiology of novel coronavirus - {region_title}-focused subsampling"



def _get_node_data_by_wildcards(wildcards):
    """Return a list of node data files to include for a given build's wildcards.
    """
    # Define inputs shared by all builds.
    wildcards_dict = dict(wildcards)
    inputs = [
        rules.refine.output.node_data,
        rules.ancestral.output.node_data,
        rules.translate.output.node_data,
        rules.clades.output.clade_data,
        rules.recency.output.node_data
    ]

    if wildcards.region in config["traits"]:
        inputs.append(rules.traits.output.node_data)

    # Convert input files from wildcard strings to real file names.
    inputs = [input_file.format(**wildcards_dict) for input_file in inputs]
    return inputs

rule export:
    message: "Exporting data files for for auspice"
    input:
        tree = rules.refine.output.tree,
        metadata = _get_metadata_by_wildcards,
        node_data = _get_node_data_by_wildcards,
        auspice_config = config["files"]["auspice_config"],
        colors = rules.colors.output.colors,
        lat_longs = config["files"]["lat_longs"],
        description = config["files"]["description"]
    output:
        auspice_json = REGION_PATH + "ncov_with_accessions.json"
    params:
        title = export_title
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        augur export v2 \
            --tree {input.tree} \
            --metadata {input.metadata} \
            --node-data {input.node_data} \
            --auspice-config {input.auspice_config} \
            --colors {input.colors} \
            --lat-longs {input.lat_longs} \
            --title {params.title:q} \
            --description {input.description} \
            --output {output.auspice_json}
        """

rule incorporate_travel_history:
    message: "Adjusting main auspice JSON to take into account travel history"
    input:
        auspice_json = rules.export.output.auspice_json,
        colors = rules.colors.output.colors,
        lat_longs = config["files"]["lat_longs"]
    params:
        sampling = _get_sampling_trait_for_wildcards,
        exposure = _get_exposure_trait_for_wildcards
    output:
        auspice_json = REGION_PATH + "ncov_with_accessions_and_travel_branches.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python3 ./scripts/modify-tree-according-to-exposure.py \
            --input {input.auspice_json} \
            --colors {input.colors} \
            --lat-longs {input.lat_longs} \
            --sampling {params.sampling} \
            --exposure {params.exposure} \
            --output {output.auspice_json}
        """

rule fix_colorings:
    message: "Remove extraneous colorings for main build"
    input:
        auspice_json = rules.incorporate_travel_history.output.auspice_json
    output:
        auspice_json = "auspice/ncov_{region}.json"
    conda: "../envs/nextstrain.yaml"
    shell:
        """
        python scripts/fix-colorings.py \
            --input {input.auspice_json} \
            --output {output.auspice_json}
        """
