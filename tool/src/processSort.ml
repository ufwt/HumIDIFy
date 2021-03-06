open Core_kernel.Std
module E = Elf
open Bap.Std

module FN = IDALink.Function
module B = IDALink.Block

module Symtab = struct

  type t = {
    syms_by_name : FN.func String.Map.t;
    syms_by_addr : FN.func Addr.Map.t;
  }

  let empty = {
    syms_by_name = String.Map.empty;
    syms_by_addr = Addr.Map.empty;
  }

  let add t fn = {
    syms_by_name = Map.add t.syms_by_name (FN.name fn) fn;
    syms_by_addr = Map.add t.syms_by_addr (FN.entry fn) fn;
  }

end

module Loader = struct

  let load_file ?path filename =
    let open Or_error in
    let (eh, shs, plt_bound, sym_strs) = In_channel.with_file filename ~binary:true ~f:(fun file ->
      let eh = E.Header.read_from_exn ~file in
      let shs = E.SectionHeader.read_from_exn ~file eh in
      
      let plt_bound = Option.value ~default:(fun _ -> false) @@
        E.Utilities.with_section_with_name eh shs ~file ~name:".plt" ~f:(fun sh ->
          let saddr = sh.E.SectionHeader.sh_addr in
          let eaddr = Int64.(saddr + sh.E.SectionHeader.sh_size) in

          Some (fun addr ->
            let addr' = Or_error.ok_exn @@ Addr.to_int64 addr in
            Int64.(saddr <= addr' && addr' < eaddr)))
      in

      let sym_strs = Option.value_exn (
        E.Utilities.with_section_with_name eh shs ~file ~name:".shstrtab" ~f:(fun sh ->
          E.StringTable.extract eh sh ~file))
      in
      (eh, shs, plt_bound, sym_strs)
    ) in
    Image.create filename >>| fun (img, _) ->
    match IDALink.load ?path img filename with
      | None -> (eh, shs, plt_bound, sym_strs, img, Symtab.empty)
      | Some fns -> (eh, shs, plt_bound, sym_strs, img, Seq.fold fns ~init:Symtab.empty ~f:Symtab.add)

end

let inclusion_delta = 0.9

let () =
  if Array.length Sys.argv >= 4 then (
    let unknown_dir = Sys.argv.(1) in
    let training_dir = Sys.argv.(2) in

    let prefix = Sys.argv.(3) in

    let input_model = Sys.argv.(4) in

    let arff_hdr = In_channel.read_all (prefix ^ ".arff") in

    let in_sexp = prefix ^ ".sexp" in
    let (cls, imps, strs) = In_channel.with_file in_sexp ~f:(fun f ->
      let cls = List.t_of_sexp String.t_of_sexp (Sexp.input_sexp f) in
      let imps = String.Set.t_of_sexp (Sexp.input_sexp f) in
      let strs = String.Set.t_of_sexp (Sexp.input_sexp f) in
      (cls, imps, strs))
    in

    let inst = ref 1 in
    let inst_map = Int.Table.create () in

    let testing_arff = Filename.temp_file "testing" ".arff" in

    Out_channel.with_file testing_arff ~f:(fun f ->
      output_string f arff_hdr;

      List.iter (FileUtil.ls unknown_dir) ~f:(fun file ->
        In_channel.with_file file ~binary:true ~f:(fun inf ->
          let open Or_error in
          try
            match Loader.load_file ~path:"/home/slt/bin/ida-6.8/idal" file with
              | Ok (_, shs, plt_bound, sym_strs, img, syms) ->
                  let sym_addrs = syms.Symtab.syms_by_addr in
                  let (imps', strs') =
                    Map.fold sym_addrs ~init:(String.Set.empty, String.Set.empty) ~f:(fun ~key ~data (imps', strs') ->
                      let imps' =
                        if plt_bound key then
                          Set.add imps' (FN.name data)
                        else
                          imps'
                      in
                      let strs' = List.fold (FN.strings data) ~init:strs' ~f:String.Set.add in
                      (imps', strs'))
                  in
                  
                  let print_string = output_string f in

                  let line = Buffer.create 10 in

                  Set.iter imps ~f:(fun imp ->
                    if Set.mem imps' imp then
                      Buffer.add_string line "1,"
                    else
                      Buffer.add_string line "0,");

                  Set.iter strs ~f:(fun str ->
                    if Set.mem strs' str then
                      Buffer.add_string line "1,"
                    else
                      Buffer.add_string line "0,");

                  print_string @@ (Buffer.contents line) ^ "?\n";

                  Int.Table.add_exn inst_map ~key:!inst ~data:(file, line);
                  inst := !inst + 1
            | _ -> ()
          with
            | _ -> ())));

    let cls_ic = Unix.open_process_in @@ sprintf "java -cp /usr/share/java/weka/weka.jar weka.classifiers.bayes.BayesNet -T %s -classifications weka.classifiers.evaluation.output.prediction.CSV -p 0 -l %s" testing_arff input_model in

    begin try
      let rec skip () =
        if input_line cls_ic <> "inst#,actual,predicted,error,prediction" then
          skip ()
      in skip ()
    with
      | exn ->
          ignore @@ Unix.close_process_in cls_ic;
          raise exn
    end;

    let split = Str.split_delim (Str.regexp ",") in

    let rec process total chosen =
      match try Some (input_line cls_ic |> split) with _ -> None with
        | Some [inst; _; pred; _; prob] ->
            let prob = Float.of_string prob in
            if prob > inclusion_delta then (
              let inst_id = Int.of_string inst in
              let label = String.drop_prefix pred (String.index_exn pred ':' + 1) in

              let (file_name, line) = Int.Table.find_exn inst_map inst_id in

              printf "%s : %s (%f)\n" file_name label prob;

              Sys.command (sprintf "mkdir -p %s/%s" training_dir label) |> ignore;
              Sys.command (sprintf "mv -f %s %s/%s/%s" file_name training_dir label (Filename.basename file_name)) |> ignore;
              process (succ total) (succ chosen)
            ) else
              process (succ total) chosen
        | None ->
            printf "%d / %d\n" total chosen
        | _ -> process (succ total) chosen
    in
    process 0 0;
    Unix.close_process_in cls_ic |> ignore;
  ) else
    print_endline "[e] cannot read from data set directory."
