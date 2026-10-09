#lang racket

;;; edit/plugin/builtin/words.rkt —— 词高亮插件（dabbrev 式）
;;;
;;; 颜色来自一张**持久表** word → 色号（state，随 document 版本走）：
;;;   · 首次见到某个词 → 取「下一个号」(= 表里已有词数)，插进表；
;;;   · 以后每次见到 → 用表里的号。
;;; 于是同词同色、不同词不同号；表只增不减，所以插新词也不会让后面的词变色。
;;; open / change 都整篇重扫，产出整篇 fills（对齐 lab）；活动词（本次编辑处）跳过。

(require racket/string
         "../registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt")

(provide word-plugin word-spec)

;; tokens 按出现顺序；skip = 活动词 (list line start end) | #f；map = 旧表。→ (values 新表 fills)
(define (assign-fills tokens skip map)
  (define out (make-hash))
  (define next (box (hash-count map)))
  (define fills
    (for/list ([tok (in-list tokens)]
               #:unless (and skip (= (car tok) (car skip)) (= (cadr tok) (cadr skip))))
      (match-define (list ln s e w) tok)
      (define idx
        (cond [(hash-ref map w #f)]          ; 见过 → 沿用（0 也是真值）
              [(hash-ref out w #f)]          ; 本趟里前面出现过
              [else (begin0 (unbox next) (set-box! next (add1 (unbox next))))]))
      (hash-set! out w idx)
      (list ln s ln e (palette-color 'word idx))))
  (define new-map (hash-copy map))
  (for ([(w i) (in-hash out)]) (hash-set! new-map w i))
  (values new-map fills))

(define (word-open text _path)
  (assign-fills (scan-words text) #f (hash)))

(define (word-change state cctx)
  (assign-fills (scan-words (string-join (vector->list (change-ctx-lines cctx)) "\n"))
                (change-ctx-active cctx)
                (or state (hash))))

(define word-plugin
  (doc-plugin 'words racket-applies? word-open word-change))

(define word-spec
  (plugin-spec 'words (lambda (s) s) (list word-plugin)))
