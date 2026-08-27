"""
Impressao digital do codigo EM EXECUCAO.

Existe por causa de um caso concreto: o worker rodou 7 dias com uma versao antiga do
marketcloud_dayparting_calibration.py. A chamada que registra a decisao do ML para
julgamento futuro (snapshot_dayparting_ml_outcome) estava no repositorio e NAO estava
no container — a imagem nunca foi reconstruida depois do commit.

Nada denunciava. A calibracao rodava e logava normalmente; a etapa ausente nao gera
erro, porque codigo que nao existe nao falha. Sem esta impressao digital a unica forma
de descobrir era o que fizemos: notar que o placar do ML estava vazio ha dias e ir ate
a raiz.

O hash e do CONTEUDO dos .py carregados, nao de metadado de build. E de proposito:
build arg mente quando a imagem e reconstruida sem o codigo mudar, e some quando alguem
builda sem passar o arg. Conteudo nao mente — se o hash mudou, o codigo mudou.

ARMADILHA QUE ESTE ARQUIVO PRECISA RESPEITAR:

O Dockerfile copia a pasta do worker E DEPOIS sobrescreve dois arquivos com as versoes
de workers/ml-worker/:

    COPY workers/modeling-worker/ .
    COPY workers/ml-worker/marketcloud_ml_worker_hourly_real_v2.py ./...
    COPY workers/ml-worker/marketcloud_ml_worker_hourly_target_real_v3.py ./...

As duas copias que ficam em workers/modeling-worker/ sao ARQUIVOS MORTOS: existem,
divergem das de ml-worker (md5 conferido em 27/08) e nunca executam. Quem editar o V3
la — o modelo que treina o ML — nao ve efeito nenhum.

Por isso o modo --repo replica a ordem do COPY. Comparar sem isso daria hash diferente
sempre, e um alarme que toca todo dia e um alarme que ninguem escuta.

USO:

    docker logs marketcloud_modeling_worker | grep CODE_FINGERPRINT
    docker run --rm -v "$PWD:/repo:ro" python:3.11-slim \
        python /repo/workers/modeling-worker/build_marker.py --repo /repo

Hashes iguais = o que roda e o que esta commitado.
"""
import hashlib
import os
import sys

# espelha os COPY do Dockerfile: origem no repositorio -> nome final em /app
SOBRESCRITOS = {
    "marketcloud_ml_worker_hourly_real_v2.py": "workers/ml-worker",
    "marketcloud_ml_worker_hourly_target_real_v3.py": "workers/ml-worker",
}


def _arquivos_do_repo(raiz_repo: str) -> dict:
    """Monta o conjunto de arquivos como o Dockerfile monta, respeitando o COPY."""
    base = os.path.join(raiz_repo, "workers", "modeling-worker")
    saida = {}
    for nome in os.listdir(base):
        if nome.endswith(".py") and nome != "__init__.py":
            saida[nome] = os.path.join(base, nome)
    # segundo COPY vence, igual no build
    for nome, origem in SOBRESCRITOS.items():
        caminho = os.path.join(raiz_repo, origem, nome)
        if os.path.isfile(caminho):
            saida[nome] = caminho
    return saida


def code_fingerprint(directory: str | None = None, raiz_repo: str | None = None):
    """Devolve (hash curto, numero de arquivos). Com raiz_repo, replica o Dockerfile."""
    if raiz_repo:
        arquivos = _arquivos_do_repo(raiz_repo)
    else:
        directory = directory or os.path.dirname(os.path.abspath(__file__))
        arquivos = {
            n: os.path.join(directory, n)
            for n in os.listdir(directory)
            if n.endswith(".py") and n != "__init__.py"
            and os.path.isfile(os.path.join(directory, n))
        }
    digest = hashlib.sha256()
    # ordenado: o hash nao pode depender da ordem que o sistema de arquivos devolve
    for nome in sorted(arquivos):
        with open(arquivos[nome], "rb") as fh:
            digest.update(nome.encode("utf-8"))  # renomear tambem e mudanca
            digest.update(fh.read())
    return digest.hexdigest()[:12], len(arquivos)


if __name__ == "__main__":
    raiz = None
    if "--repo" in sys.argv:
        raiz = sys.argv[sys.argv.index("--repo") + 1]
    h, n = code_fingerprint(raiz_repo=raiz)
    print(f"CODE_FINGERPRINT {h} arquivos={n}")
