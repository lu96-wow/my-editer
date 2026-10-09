#lang racket

;;; edit/plugin/builtin/words.rkt —— 词高亮插件（dabbrev 式）
;;;
;;; 配色两种策略（见 config/words.rkt；运行时可用 word-coloring-method 覆盖）：
;;;   sequential（默认）：颜色来自一张**持久表** word → 色号（state，随 document 版本走）：
;;;       · 首次见到某词 → 取「下一个号」(= 表里已有词数)，插进表；
;;;       · 以后每次见到 → 用表里的号。
;;;     同词同色、不同词不同号；表只增不减 → 插新词不让后面的词变色。
;;;   hash：颜色 = hash(词名)，**无状态**、跨文件 / 会话稳定（可能撞色）。
;;; 层 = 每行 face 向量（行局部），只重扫脏行；活动词跳过，
;;; 上一次活动词所在行也重扫（避免旧词永不上色）。

(require "../registry.rkt"
         "../../core/lex.rkt"
         "../../core/file-kind.rkt"
         "../../core/face.rkt"
         "../../core/line-scan.rkt"
         "../../config/words.rkt")

(provide word-plugin word-spec word-coloring-method)

;; 配色策略：默认取 config；可 parameterize（测试 / 运行时覆盖）。
(define word-coloring-method (make-parameter word-coloring))
(unless (memq (word-coloring-method) '(sequential hash))
  (error 'words "未知词配色策略: ~a" (word-coloring-method)))

;; 稳定散列（djb2）：跨会话 / 跨 place 一致，不依赖 equal-hash-code 的随机性。
(define (word-hash w)
  (for/fold ([h 5381]) ([c (in-string w)])
    (bitwise-and (+ (* h 33) (char->integer c)) #xFFFFFFFF)))

(define (hash-color-of w)
  (palette-color 'word (modulo (word-hash w) (max 1 word-color-count))))

;; 顺序发号：只在表里没有该词时取「下一个号」（0 也是真值）。
(define (sequential-color-of table next)
  (lambda (w)
    (define idx
      (or (hash-ref table w #f)
          (let ([i (unbox next)]) (set-box! next (add1 i)) (hash-set! table w i) i)))
    (palette-color 'word idx)))

;; 行 → face 向量（无词 → #f）。active = (list line start end) | #f（跳过它）。
(define (word-line color-of active line-no line)
  (define n (string-length line))
  (define faces (make-vector n #f))
  (define touched? #f)
  (for ([m (in-list (line-tokens line))])
    (define start (car m))
    (define end (cdr m))
    (define w (substring line start end))
    (unless (and active (= line-no (car active)) (= start (cadr active)))
      (set! touched? #t)
      (define f (color-of w))
      (for ([i (in-range start end)]) (vector-set! faces i f))))
  (and touched? faces))

(define (word-open text _path)
  (case (word-coloring-method)
    [(hash)
     (values #f (scan-track text (lambda (ln line) (word-line hash-color-of #f ln line))))]
    [(sequential)
     (define table (make-hash))
     (define next (box 0))
     (values table
             (scan-track text (lambda (ln line)
                                (word-line (sequential-color-of table next) #f ln line))))]
    [else (error 'words "未知词配色策略: ~a" (word-coloring-method))]))

(define (word-change table layer ctx)
  (define active (face-ctx-active ctx))
  (define dirty (active-dirty ctx))
  (define dlines (dirty-ls dirty))
  (case (word-coloring-method)
    [(hash)
     (values #f
             (refresh-layer layer (face-ctx-new-text ctx) dlines
                            (lambda (ln line) (word-line hash-color-of active ln line)))
             dirty)]
    [(sequential)
     (define new-table (hash-copy (or table (hash))))   ; 新版本新表（不动旧值）
     (define next (box (hash-count new-table)))
     (values new-table
             (refresh-layer layer (face-ctx-new-text ctx) dlines
                            (lambda (ln line)
                              (word-line (sequential-color-of new-table next) active ln line)))
             dirty)]
    [else (error 'words "未知词配色策略: ~a" (word-coloring-method))]))

(define word-plugin
  (face-plugin 'words racket-applies? word-open word-change))

(define word-spec
  (plugin-spec 'words (lambda (s) s) (list word-plugin)))
