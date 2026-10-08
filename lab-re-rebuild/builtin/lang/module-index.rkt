#lang racket

;;; lab/builtin/lang/module-index.rkt —— 已安装模块路径索引（require 补全用，纯缓存）。
;;;
;;; 从 collects 搜索目录 + 包目录收集 `*.rkt`/`*.ss`，转成模块路径字符串
;;; （去扩展名；`main` → 目录名，`racket/main.rkt` → `racket`）。
;;; 首次使用惰性构建、排序去重。只为补全候选，个别噪声可接受。

(require racket/file racket/list racket/path racket/string
         setup/dirs)

(provide module-paths)

(define rkt-exts '(#".rkt" #".ss" #".rktl" #".rktd"))

(define (rkt-file? p)
  (and (file-exists? p) (member (path-get-extension p) rkt-exts)))

;; 相对路径 → 模块路径：去扩展名；`main` 段去掉（指向所在集合 / 目录）。
(define (rel->module rel)
  (define noext (regexp-replace #rx"[.](rkt|ss|rktl|rktd)$" (path->string rel) ""))
  (regexp-replace #rx"(^|/)main$" noext ""))

;; root 下所有 .rkt 的模块路径（prefix = 集合名，可为 ""）。
(define (dir-modules root [prefix ""])
  (for/list ([f (in-directory root)]
             #:when (rkt-file? f))
    (define rel (rel->module (find-relative-path root f)))
    (cond [(string=? rel "") prefix]
          [(string=? prefix "") rel]
          [else (string-append prefix "/" rel)])))

(define (collects-modules)
  (append* (for/list ([d (in-list (get-collects-search-dirs))]
                      #:when (directory-exists? d))
             (dir-modules d))))

(define deny-dirs '("compiled" "doc" "docs" ".git" "tests" "test"))

;; 包目录：每个 <pkg>/<collection>/ 当作一个集合（collection 名 = 目录名）。
(define (pkg-modules)
  (append*
   (for*/list ([pkgsdir (in-list (list (find-pkgs-dir) (find-user-pkgs-dir)))]
          #:when (and pkgsdir (directory-exists? pkgsdir))
          [pkg (in-list (directory-list pkgsdir))]
          #:when (directory-exists? (build-path pkgsdir pkg))
          [coll (in-list (directory-list (build-path pkgsdir pkg)))]
          #:when (and (directory-exists? (build-path pkgsdir pkg coll))
                      (not (member (path->string coll) deny-dirs))))
     (dir-modules (build-path pkgsdir pkg coll) (path->string coll)))))

;; 排序去重的模块路径表（惰性；首次 require 补全时构建）。
(define module-paths
  (delay
    (sort (remove-duplicates (append (collects-modules) (pkg-modules)) equal?)
          string<?)))
