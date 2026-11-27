#lang racket

;;; edit-tui/lang/racket/color/color.rkt —— 增量语法高亮 + 同词着色 + 括号深度（纯）
;;;
;;; 缓存单位是“行”：
;;;   lex-out-states     : 每行的出状态（块注释深度 / 是否在字符串里）
;;;   bracket-out-states : 每行的出括号栈
;;;   syntax-roles       : 每行的语法 role 向量
;;;   word-roles         : 每行的同词 role 向量
;;;   bracket-roles      : 每行的括号深度 role 向量
;;;
;;; color-edit 只做：
;;;   1. 按 line-edit 的 old 区间 splice 五组行缓存；
;;;   2. 从最小脏行开始重扫；
;;;   3. 词法状态或括号栈变化时继续向后推进，直到两个出状态都收敛；
;;;   4. 到达最后一个脏行且状态不变即可停。
;;;
;;; 同词色没有跨行状态，但因为和语法 / 括号共用一次 tokenize，脏行一起更新。

(provide (struct-out color-state)
         color-open
         color-open-lines
         color-edit
         color-edit*
         color-edit*/lines
         color-syntax-roles
         color-word-roles
         color-bracket-roles
         color-line-count)

(require racket/list
         racket/string
         "../base/edit.rkt"
         "../base/lex.rkt"
         "highlight.rkt"
         "word-color.rkt"
         "bracket.rkt")

(struct color-state
  (lex-out-states     ; vector line -> 行尾词法状态
   bracket-out-states ; vector line -> 行尾括号栈
   syntax-roles       ; vector line -> (vector role|#f)
   word-roles         ; vector line -> (vector role|#f)
   bracket-roles)     ; vector line -> (vector role|#f)
  #:transparent)

(define (color-open text)
  (color-open-lines (split-lines text)))

;; 一行只遍历一次 token：同时产出 bracket / syntax / word 三组 role。
;; 之前是 token 流分别喂给 bracket-scan-line、highlight-line、word-color-line，
;; 同一个 token 列表走三遍。symbol token 的 substring 也只取一次。
(define (color-line-roles tokens line stack)
  (define n (string-length line))
  (define syntax (make-vector n #f))
  (define word (make-vector n #f))
  (define bracket (make-vector n #f))
  (define stack*
    (for/fold ([st stack]) ([t (in-list tokens)])
      (define a (token-start t))
      (define b (min (token-end t) n))
      (define kind (token-kind t))
      (cond
        ;; 括号 token 要逐字符维护栈，交给 bracket 层；syntax/word 对它没有 role。
        [(eq? kind 'paren)
         (bracket-scan-token! bracket t line st)]
        [else
         ;; 非括号 token 的 bracket 内容是同一个 role，和 syntax / word
         ;; 在同一个字符循环里写入，避免再单独扫一遍。
         (define w (and (eq? kind 'symbol) (substring line a b)))
         (define sr (if w (keyword-role w) (lexical-role kind)))
         (define wr (and w (word-color-role w)))
         (define br (bracket-content-role st))
         (for ([i (in-range a b)])
           (when sr (vector-set! syntax i sr))
           (when wr (vector-set! word i wr))
           (when br (vector-set! bracket i br)))
         st])))
  (values stack* syntax word bracket))

;; 直接吃行表：调用方（engine）已经能拿到 track 的行，避免再把全文 join
;; 成 string 后重新 split。lines 的顺序 / 空行语义与 (split-lines text) 一致。
(define (color-open-lines lines)
  (let loop ([lines lines]
             [state empty-lex-state]
             [bracket '()]
             [states '()]
             [bracket-states '()]
             [syntax '()]
             [word '()]
             [bracket-roles '()])
    (cond
      [(null? lines)
       (color-state (list->vector (reverse states))
                    (list->vector (reverse bracket-states))
                    (list->vector (reverse syntax))
                    (list->vector (reverse word))
                    (list->vector (reverse bracket-roles)))]
      [else
       (define line (car lines))
       (define-values (state* tokens) (tokenize-line state line))
       (define-values (bracket* syntax-vec word-vec bracket-vec)
         (color-line-roles tokens line bracket))
       (loop (cdr lines) state* bracket*
             (cons state* states)
             (cons bracket* bracket-states)
             (cons syntax-vec syntax)
             (cons word-vec word)
             (cons bracket-vec bracket-roles))])))

(define (color-line-count cache)
  (vector-length (color-state-syntax-roles cache)))

(define (color-syntax-roles cache)
  (vector->list (color-state-syntax-roles cache)))

(define (color-word-roles cache)
  (vector->list (color-state-word-roles cache)))

(define (color-bracket-roles cache)
  (vector->list (color-state-bracket-roles cache)))

;; cache 必须对应旧文本；text 是新文本；edits 是旧→新行区间。
(define (color-edit cache text edits)
  (let-values ([(state _dirty) (color-edit* cache text edits)])
    state))

;; 返回 (values color-state' dirty-lines)。
;; dirty-lines : (listof line-no) | 'all
(define (color-edit* cache text edits)
  (color-edit*/lines cache (split-lines text) edits))

;; lines : (listof string) 或 vector。大文件编辑时调用方传行表，
;; 避免每次编辑都 split 全文。
(define (color-edit*/lines cache lines edits)
  (if (null? edits)
      (values cache '())
      (let* ([linev (if (vector? lines) lines (list->vector lines))]
             [n (vector-length linev)]
             [old-states (color-state-lex-out-states cache)]
             [old-bracket-states (color-state-bracket-out-states cache)]
             [old-syntax (color-state-syntax-roles cache)]
             [old-word (color-state-word-roles cache)]
             [old-bracket (color-state-bracket-roles cache)])
        (define-values (states0 bracket-states0 syntax0 word0 bracket0)
          (for/fold ([st old-states]
                     [bst old-bracket-states]
                     [syn old-syntax]
                     [wd old-word]
                     [br old-bracket])
                    ([sp (in-list (edit-spans edits))])
            (define old-start (car sp))
            (define old-end (cadr sp))
            (define new-count (max 0 (- (cadddr sp) (caddr sp))))
            (values (splice-vector-preserve st old-start old-end new-count)
                    (splice-vector-preserve bst old-start old-end new-count)
                    (splice-vector-preserve syn old-start old-end new-count)
                    (splice-vector-preserve wd old-start old-end new-count)
                    (splice-vector-preserve br old-start old-end new-count))))

        ;; 边界：splice 后所有缓存向量都必须和新文本行数一致。
        ;; change 行区间失配（旧缓存 / 多 change / 跨行替换）时不能继续
        ;; vector-set!，直接退回全量，避免越界。
        (if (or (not (= (vector-length states0) n))
                (not (= (vector-length bracket-states0) n))
                (not (= (vector-length syntax0) n))
                (not (= (vector-length word0) n))
                (not (= (vector-length bracket0) n)))
            (values (color-open-lines (if (vector? lines) (vector->list lines) lines)) 'all)
            (let ([dirty (edits->dirty-lines edits n)])
              (if (null? dirty)
                  (values (color-state states0 bracket-states0 syntax0 word0 bracket0) '())
                  (color-edit-dirty linev n
                                    states0 bracket-states0
                                    syntax0 word0 bracket0
                                    dirty)))))))

;; 从脏行开始带状态重扫；两个出状态都收敛后停止。
;; 返回 (values color-state' touched-lines)。
(define (color-edit-dirty lines n
                          states* bracket-states*
                          syntax* word* bracket*
                          dirty)
  (define start (car dirty))
  (define last-dirty (last dirty))
  (let loop ([ln start]
             [incoming (if (and (> start 0)
                                (< (sub1 start) (vector-length states*)))
                           (vector-ref states* (sub1 start))
                           empty-lex-state)]
             [incoming-bracket (if (and (> start 0)
                                        (< (sub1 start) (vector-length bracket-states*)))
                                  (vector-ref bracket-states* (sub1 start))
                                  '())]
             [touched '()])
    (cond
      [(>= ln n)
       (values (color-state states* bracket-states* syntax* word* bracket*)
               (reverse touched))]
      [else
       (define line (vector-ref lines ln))
       (define-values (state* tokens) (tokenize-line incoming line))
       (define-values (bracket-state* syntax-vec word-vec bracket-vec)
         (color-line-roles tokens line incoming-bracket))
       ;; splice 出来的向量已是最新副本，可以直接改写；改写前先取旧值判断收敛。
       (define old-state (vector-ref states* ln))
       (define old-bracket-state (vector-ref bracket-states* ln))
       (define changed?
         (not (and (equal? state* old-state)
                   (equal? bracket-state* old-bracket-state))))
       (vector-set! states* ln state*)
       (vector-set! bracket-states* ln bracket-state*)
       (vector-set! syntax* ln syntax-vec)
       (vector-set! word* ln word-vec)
       (vector-set! bracket* ln bracket-vec)
       (if (and (>= ln last-dirty) (not changed?))
           (values (color-state states* bracket-states* syntax* word* bracket*)
                   (reverse (cons ln touched)))
           (loop (add1 ln) state* bracket-state* (cons ln touched)))])))
