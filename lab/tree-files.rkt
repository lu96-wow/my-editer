#lang racket

;;; ============================================================================
;;; tree-files.rkt —— 文件树用到的文件系统动作（与树结构无关）
;;; ============================================================================
;;;
;;; 只做「名字 ↔ 磁盘」：列目录排序、去重命名、建文件 / 目录、删除。
;;; 不认识树、不认识文档、不认识输入。任何别的地方要建/删文件都可以直接用它。

(require "fs.rkt")

(provide list-dir unique-name create-file! create-dir! remove! parent-path)

;; 目录项排序：文件夹在前，然后按名字。
(define (list-dir dir)
  (sort (fs-list dir)
        (lambda (x y)
          (cond [(and (entry-dir? x) (not (entry-dir? y))) #t]
                [(and (entry-dir? y) (not (entry-dir? x))) #f]
                [else (string<? (entry-name x) (entry-name y))]))))

;; 同一目录下重名 → name-2 / name-3 …
(define (unique-name dir name)
  (define names (for/list ([e (in-list (fs-list dir))]) (entry-name e)))
  (if (not (member name names))
      name
      (let loop ([i 2])
        (define cand (format "~a-~a" name i))
        (if (member cand names) (loop (add1 i)) cand))))

;; → 实际建出的绝对路径。
(define (create-file! dir name)
  (define path (build-path dir (unique-name dir name)))
  (fs-create path)
  path)
(define (create-dir! dir name)
  (define path (build-path dir (unique-name dir name)))
  (fs-mkdir path)
  path)

(define (remove! path) (fs-delete path) path)

;; 父目录（统一去尾斜杠）。
(define (parent-path p)
  (canon-path (let-values ([(base _n _d) (split-path p)]) base)))
